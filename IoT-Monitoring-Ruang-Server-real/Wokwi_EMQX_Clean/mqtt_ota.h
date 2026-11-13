#pragma once

#include <Arduino.h>
#include <atomic>
#include <freertos/semphr.h>
#include <esp_app_desc.h>
#include <esp_ota_ops.h>
#include <mbedtls/sha256.h>
#include <mqtt_client.h>
#include <freertos/queue.h>

namespace FirmwareOta {
constexpr size_t CHUNK_SIZE = 4096;
constexpr size_t WINDOW_SIZE = 8;
constexpr size_t ID_SIZE = 16;
constexpr size_t MANIFEST_SIZE = ID_SIZE + 4 + 32;
constexpr unsigned long TRANSFER_TIMEOUT = 30000;
constexpr unsigned long VERIFY_TIMEOUT = 180000;
constexpr char FILTER[] = MQTT_ROOT "/action/ota/+";
constexpr char STATUS_TOPIC[] = MQTT_ROOT "/state/ota";
constexpr char FIRMWARE_TOPIC[] = MQTT_ROOT "/state/firmware";

enum class Command { Begin, Chunk, End, Verify };
struct Packet {
  Command command;
  size_t size;
  uint8_t data[ID_SIZE + 4 + CHUNK_SIZE];
};

static QueueHandle_t inbox = nullptr;
static QueueHandle_t chunkQueue = nullptr;
static SemaphoreHandle_t chunkQueueLock = nullptr;
// Offset berikutnya yang boleh masuk antrean, termasuk data yang belum ditulis.
static size_t queuedUntil = 0;
static std::atomic<bool> transferring{false};
static const esp_partition_t* target = nullptr;

inline bool isTransferring() { return transferring.load(); }
static esp_ota_handle_t handle;
static mbedtls_sha256_context sha;
static uint8_t expected[32];
static size_t total = 0;
static size_t received = 0;
static char transferId[ID_SIZE + 1] = {};
static char buildId[65] = {};
static unsigned long lastPacket = 0;
static unsigned long bootTime = 0;
static bool verifying = false;
static bool firmwareDirty = true;
static unsigned long lastProgressReport = 0;

void toHex(const uint8_t* bytes, char* hex) {
  constexpr char digits[] = "0123456789abcdef";
  for (size_t i = 0; i < 32; ++i) {
    hex[2 * i] = digits[bytes[i] >> 4];
    hex[2 * i + 1] = digits[bytes[i] & 15];
  }
  hex[64] = '\0';
}

int hexValue(uint8_t ch) {
  if (ch >= '0' && ch <= '9') return ch - '0';
  if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
  return -1;
}

void setup() {
  inbox = xQueueCreate(1, sizeof(Packet));
  chunkQueueLock = xSemaphoreCreateMutex();
  toHex(esp_app_get_description()->app_elf_sha256, buildId);
  esp_ota_img_states_t state{};
  verifying = esp_ota_get_state_partition(esp_ota_get_running_partition(), &state) == ESP_OK &&
              state == ESP_OTA_IMG_PENDING_VERIFY;
  bootTime = millis();
}

size_t chunkOffset(const Packet& packet) {
  const uint8_t* pos = packet.data + ID_SIZE;
  return (uint32_t(pos[0]) << 24) | (uint32_t(pos[1]) << 16) |
         (uint32_t(pos[2]) << 8) | pos[3];
}

bool receive(esp_mqtt_event_handle_t event) {
  // ESP-MQTT dapat membagi satu payload menjadi beberapa event DATA.
  static Packet packet;
  static size_t filled = 0;
  static bool assembling = false;
  constexpr char prefix[] = MQTT_ROOT "/action/ota/";
  constexpr size_t prefixSize = sizeof(prefix) - 1;

  if (event->current_data_offset == 0) {
    assembling = false;
    if (!event->topic || event->topic_len <= prefixSize ||
        memcmp(event->topic, prefix, prefixSize) != 0) return false;
    if (!inbox || event->retain || event->total_data_len <= 0 ||
        static_cast<size_t>(event->total_data_len) > sizeof(packet.data)) return true;

    const char* suffix = event->topic + prefixSize;
    const size_t length = event->topic_len - prefixSize;
    if (length == 5 && memcmp(suffix, "begin", 5) == 0) packet.command = Command::Begin;
    else if (length == 5 && memcmp(suffix, "chunk", 5) == 0) packet.command = Command::Chunk;
    else if (length == 3 && memcmp(suffix, "end", 3) == 0) packet.command = Command::End;
    else if (length == 6 && memcmp(suffix, "verify", 6) == 0) packet.command = Command::Verify;
    else return true;

    packet.size = event->total_data_len;
    filled = 0;
    assembling = true;
  }

  if (!assembling) return false;
  if (event->current_data_offset != static_cast<int>(filled) || !event->data ||
      event->data_len <= 0 || static_cast<size_t>(event->data_len) > packet.size - filled) {
    assembling = false;
    return true;
  }

  memcpy(packet.data + filled, event->data, event->data_len);
  filled += event->data_len;
  if (filled < packet.size) return true;
  assembling = false;
  if (packet.command == Command::Chunk) {
    if (chunkQueueLock && xSemaphoreTake(chunkQueueLock, portMAX_DELAY) == pdTRUE) {
      if (chunkQueue && packet.size > ID_SIZE + 4 &&
          memcmp(packet.data, transferId, ID_SIZE) == 0 &&
          chunkOffset(packet) == queuedUntil) {
        const size_t length = packet.size - ID_SIZE - 4;
        if (length <= total - queuedUntil &&
            xQueueSend(chunkQueue, &packet, 0) == pdPASS) {
          queuedUntil += length;
        }
      }
      xSemaphoreGive(chunkQueueLock);
    }
    return true;
  }

  if (xQueueSend(inbox, &packet, 0) != pdPASS) {
    Serial.println("OTA: antrean penuh.");
  }
  return true;
}

void report(esp_mqtt_client_handle_t mqtt, const char* state, const char* reason = "") {
  char json[160];
  snprintf(json, sizeof(json), "{\"id\":\"%s\",\"status\":\"%s\",\"received\":%u,\"reason\":\"%s\"}",
           transferId, state, static_cast<unsigned>(received), reason);
  if (esp_mqtt_client_enqueue(mqtt, STATUS_TOPIC, json, 0, 1, false, false) >= 0) {
    lastProgressReport = millis();
  }
}

// Hanya loop() membuat dan melepas antrean. Callback MQTT mengirim di bawah mutex.
void releaseTransferQueue() {
  xSemaphoreTake(chunkQueueLock, portMAX_DELAY);
  vQueueDelete(chunkQueue);
  chunkQueue = nullptr;
  xSemaphoreGive(chunkQueueLock);
  transferring = false;
}

void abortTransfer(esp_mqtt_client_handle_t mqtt, const char* reason) {
  esp_ota_abort(handle);
  mbedtls_sha256_free(&sha);
  target = nullptr;
  releaseTransferQueue();
  report(mqtt, "error", reason);
}

void beginTransfer(esp_mqtt_client_handle_t mqtt, const Packet& packet) {
  // ID, panjang big endian, dan SHA-256 firmware.
  if (packet.size != MANIFEST_SIZE) return;
  for (size_t i = 0; i < ID_SIZE; ++i) {
    if (hexValue(packet.data[i]) < 0) return;
  }
  if (target) {
    if (memcmp(packet.data, transferId, ID_SIZE) == 0 && received == 0) {
      lastPacket = millis();
      report(mqtt, "ready");
    }
    return;
  }
  memcpy(transferId, packet.data, ID_SIZE);
  received = 0;
  const uint8_t* size = packet.data + ID_SIZE;
  total = (uint32_t(size[0]) << 24) | (uint32_t(size[1]) << 16) |
          (uint32_t(size[2]) << 8) | size[3];
  const auto* slot = esp_ota_get_next_update_partition(nullptr);
  if (verifying || !slot || total == 0 || total > slot->size) {
    report(mqtt, "error", slot && total > slot->size ? "image_too_large" : "slot_or_size");
    return;
  }
  if (!chunkQueueLock) {
    report(mqtt, "error", "ota_queue_unavailable");
    return;
  }
  xSemaphoreTake(chunkQueueLock, portMAX_DELAY);
  queuedUntil = 0;
  chunkQueue = xQueueCreate(WINDOW_SIZE, sizeof(Packet));
  xSemaphoreGive(chunkQueueLock);
  if (!chunkQueue) {
    report(mqtt, "error", "ota_queue_no_memory");
    return;
  }
  transferring = true;
  if (esp_ota_begin(slot, OTA_WITH_SEQUENTIAL_WRITES, &handle) != ESP_OK) {
    releaseTransferQueue();
    report(mqtt, "error", "begin_failed");
    return;
  }
  target = slot;
  memcpy(expected, size + 4, sizeof(expected));
  mbedtls_sha256_init(&sha);
  if (mbedtls_sha256_starts(&sha, 0) != 0) {
    abortTransfer(mqtt, "sha256_failed");
    return;
  }
  lastPacket = millis();
  report(mqtt, "ready");
}

void process(esp_mqtt_client_handle_t mqtt, const Packet& packet) {
  if (packet.command == Command::Verify) {
    if (packet.size == 64 && memcmp(packet.data, buildId, 64) == 0 &&
        (!verifying || esp_ota_mark_app_valid_cancel_rollback() == ESP_OK)) {
      verifying = false;
      firmwareDirty = true;
      Serial.println("OTA: firmware terverifikasi.");
    }
    return;
  }
  if (packet.command == Command::Begin) {
    beginTransfer(mqtt, packet);
    return;
  }
  if (!target || packet.size < ID_SIZE || memcmp(packet.data, transferId, ID_SIZE) != 0) return;
  lastPacket = millis();

  if (packet.command == Command::Chunk && packet.size > ID_SIZE + 4) {
    const uint8_t* pos = packet.data + ID_SIZE;
    const size_t offset = chunkOffset(packet);
    const size_t length = packet.size - ID_SIZE - 4;
    if (offset != received) {
      // Laporkan posisi terakhir agar pengirim bisa mengulang dari sana.
      report(mqtt, "receiving");
      return;
    }
    if (length > total - received ||
        esp_ota_write(handle, pos + 4, length) != ESP_OK ||
        mbedtls_sha256_update(&sha, pos + 4, length) != 0) {
      abortTransfer(mqtt, "chunk_failed");
      return;
    }
    received += length;
    report(mqtt, "receiving");
    return;
  }

  if (packet.command != Command::End || packet.size != ID_SIZE) return;
  uint8_t actual[32];
  if (received != total || mbedtls_sha256_finish(&sha, actual) != 0 ||
      memcmp(actual, expected, sizeof(actual)) != 0) {
    abortTransfer(mqtt, "size_or_sha256_mismatch");
    return;
  }
  mbedtls_sha256_free(&sha);
  const auto* slot = target;
  target = nullptr;
  releaseTransferQueue();
  if (esp_ota_end(handle) != ESP_OK || esp_ota_set_boot_partition(slot) != ESP_OK) {
    report(mqtt, "error", "image_or_boot_failed");
    return;
  }
  Serial.println("OTA: image valid. Restart.");
  ESP.restart();
}

void service(esp_mqtt_client_handle_t mqtt, bool connected, bool resync) {
  if (verifying && millis() - bootTime >= VERIFY_TIMEOUT) {
    Serial.println("OTA: verifikasi timeout, rollback.");
    const esp_err_t error = esp_ota_mark_app_invalid_rollback_and_reboot();
    Serial.printf("OTA: rollback gagal: %s\n", esp_err_to_name(error));
    bootTime = millis();
  }
  if (target && millis() - lastPacket >= TRANSFER_TIMEOUT) {
    abortTransfer(mqtt, "timeout");
  }
  firmwareDirty = firmwareDirty || resync;
  if (!connected) return;
  if (firmwareDirty) {
    char json[256];
    const auto* slot = esp_ota_get_next_update_partition(nullptr);
    snprintf(json, sizeof(json),
             "{\"build_id\":\"%s\",\"version\":\"%s\",\"verification\":\"%s\",\"ota_chunk_size\":%u,\"ota_window\":%u,\"ota_max_size\":%u}",
             buildId, FIRMWARE_VERSION, verifying ? "pending" : "valid",
             static_cast<unsigned>(CHUNK_SIZE), static_cast<unsigned>(inbox && chunkQueueLock ? WINDOW_SIZE : 0),
             static_cast<unsigned>(slot ? slot->size : 0));
    firmwareDirty = esp_mqtt_client_enqueue(mqtt, FIRMWARE_TOPIC, json, 0, 1, true, false) < 0;
  }
  // Ulangi posisi terakhir jika konfirmasi hilang atau outbox sebelumnya penuh.
  if (target && millis() - lastProgressReport >= 1000) {
    report(mqtt, received == 0 ? "ready" : "receiving");
  }
  // Buffer statis agar paket besar tidak memenuhi stack task.
  static Packet packet;
  if (chunkQueue && xQueueReceive(chunkQueue, &packet, 0) == pdPASS) {
    process(mqtt, packet);
  } else if (inbox && xQueueReceive(inbox, &packet, 0) == pdPASS) {
    process(mqtt, packet);
  }
}
}
