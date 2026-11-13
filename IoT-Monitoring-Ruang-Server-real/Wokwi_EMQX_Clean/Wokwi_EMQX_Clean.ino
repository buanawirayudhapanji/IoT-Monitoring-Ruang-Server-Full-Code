#include <Arduino.h>
#include <Wire.h>
#include <DHT.h>
#include <Adafruit_BMP085.h>
#include <WiFi.h>
#include <mqtt_client.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <atomic>
#include <cmath>
#include <cstring>
#include <ctime>

#include "mqtt_ca.h"

// --- Konfigurasi Wi-Fi dan MQTT ---
#define RUN_IN_WOKWI false

#define HOME_WIFI_SSID "indihoyy"
#define HOME_WIFI_PASSWORD "12345678"

#define MQTT_URI "wss://mqtt-wss.wyb.my.id:443/mqtt"
#define MQTT_USER "Sertifikasi-ESP32"
#define MQTT_PASSWORD "Qwerty789$"

#define MQTT_DEVICE_ID "esp32-01"
#define MQTT_ROOT "iot/server-room/" MQTT_DEVICE_ID

#define FIRMWARE_VERSION "v.3.06"
#include "mqtt_ota.h"

#define CLIENT_ID "server-room-" MQTT_DEVICE_ID

#define TELEMETRY_TOPIC MQTT_ROOT "/telemetry"

#define ACTION_FILTER MQTT_ROOT "/action/led/+"
#define VOLUME_ACTION_TOPIC MQTT_ROOT "/action/buzzer/volume"
#define VOLUME_STATE_TOPIC MQTT_ROOT "/state/buzzer/volume"
#define RELAY_AUTO_ACTION MQTT_ROOT "/action/relay/auto"
#define RELAY_SWITCH_ACTION MQTT_ROOT "/action/relay/power"
#define RELAY_AUTO_STATE MQTT_ROOT "/state/relay/auto"
#define RELAY_SWITCH_STATE MQTT_ROOT "/state/relay/power"

#define AVAILABILITY_TOPIC MQTT_ROOT "/state/availability"

#define CONDITION_TOPIC MQTT_ROOT "/state/condition"

// --- Pin dan interval ESP32 ---
#define DHT_PIN 27
// Sesuaikan dengan sensor yang terpasang: DHT11 atau DHT22.
#define DHT_TYPE DHT11
#define BMP_SDA 21
#define BMP_SCL 22
#define BMP_ADDRESS 0x77

#define LED_RED 4
#define LED_GREEN 17
#define LED_BLUE 2
#define LED_YELLOW 16

// Sesuaikan pin dan polaritas dengan modul relay yang dipasang.
#define RELAY_PIN 32
#define RELAY_ON HIGH
#define RELAY_OFF LOW

#define BUZZER_PIN 13
#define BUZZER_ON HIGH
#define BUZZER_OFF LOW
#define POT_PIN 36
#define POT_CHANGE_THRESHOLD 3
#define BEEP_MS 150UL

#define LED_ON HIGH
#define LED_OFF LOW

#define READ_INTERVAL_MS 5000UL
#define DHT_RETRY_MS 2000UL

#define MIN_TLS_TIME 1704067200

// --- Data LED dan sensor ---
struct Led {
  int pin;
  const char* actionTopic;
  const char* stateTopic;
};

const Led leds[] = {{LED_RED, MQTT_ROOT "/action/led/red", MQTT_ROOT "/state/led/red"},
                    {LED_YELLOW, MQTT_ROOT "/action/led/yellow", MQTT_ROOT "/state/led/yellow"},
                    {LED_GREEN, MQTT_ROOT "/action/led/green", MQTT_ROOT "/state/led/green"},
                    {LED_BLUE, MQTT_ROOT "/action/led/blue", MQTT_ROOT "/state/led/blue"}};

const int LED_COUNT = sizeof(leds) / sizeof(leds[0]);

struct LedAction {
  int index;
  bool on;
};

struct RelayAction {
  bool changesMode;
  bool on;
};

enum RangeStatus { IN_RANGE, BELOW_MIN, ABOVE_MAX };
const int ROOM_RULE_COUNT = 3;
const int TEMPERATURE_RULE = 0;

struct SensorReading {
  float temperature;
  float humidity;
  float pressure;
  float bmpTemperature;
  bool dhtOk;
  bool bmpOk;
  RangeStatus ranges[ROOM_RULE_COUNT];
};

struct RoomRule {
  const char* parameter;
  float value;
  float min;
  float max;
};

void readRoomRules(const SensorReading& reading, RoomRule rules[]);

void readRoomRules(const SensorReading& reading, RoomRule rules[]) {
  rules[TEMPERATURE_RULE] = {"temperature_c", reading.temperature, 18, 27};
  rules[1] = {"humidity_pct", reading.humidity, 30, 60};
  rules[2] = {"pressure_hpa", reading.pressure, 980, 1040};
}

// --- Status yang dipakai antar-task ---
esp_mqtt_client_handle_t mqtt = nullptr;

// MQTT memasukkan perintah ke antrean, task LED yang mengubah pin.
QueueHandle_t actionQueue = nullptr;
QueueHandle_t relayQueue = nullptr;
// Callback MQTT menyimpan perintah terbaru. loop() menerapkannya ke buzzer.
std::atomic<int> requestedVolume{-1};
// Antrean satu slot menyimpan bacaan sensor terbaru untuk loop().
QueueHandle_t latestReading = nullptr;

std::atomic<bool> mqttConnected{false};
std::atomic<bool> syncState{false};

std::atomic<uint32_t> ledMask{0};
std::atomic<uint32_t> dirtyLeds{0};

const uint32_t ALL_LEDS = (1u << LED_COUNT) - 1;

void evaluateCondition(SensorReading& reading);
void readDht(DHT& dht, SensorReading& reading);
void readBmp(Adafruit_BMP085& bmp, bool& bmpReady, SensorReading& reading);
void printSensorReading(const SensorReading& reading);
void publishTelemetry(const SensorReading& reading);
bool publishCondition(const SensorReading& reading);

extern "C" bool verifyRollbackLater() { return true; }

// --- Informasi saat perangkat menyala ---
void printSystemInfo() {
  Serial.println();
  Serial.println("================================");
  Serial.println("DOIT ESP32 DEVKIT V1");
  Serial.println("BOOT BERHASIL");
  Serial.println("================================");
  Serial.printf("[SYSTEM] CPU: %u MHz\n", ESP.getCpuFreqMHz());
  Serial.printf("[SYSTEM] Free Heap: %u bytes\n", ESP.getFreeHeap());
  Serial.printf("[SYSTEM] Flash: %u bytes\n", ESP.getFlashChipSize());
  Serial.printf("[SYSTEM] Reset Reason: %d\n", static_cast<int>(esp_reset_reason()));
  Serial.println("================================");
}

// --- Kontrol LED ---
void runLedTask(void*) {
  Serial.println("[LED] Task berjalan.");

  LedAction action{};

  while (true) {
    if (xQueueReceive(actionQueue, &action, portMAX_DELAY) != pdPASS) {
      continue;
    }

    const Led& led = leds[action.index];
    // Satu bit untuk setiap LED agar task LED dan loop() bisa bertukar status.
    const uint32_t bit = 1u << action.index;

    while (FirmwareOta::isTransferring()) {
      vTaskDelay(pdMS_TO_TICKS(50));
    }
    digitalWrite(led.pin, action.on ? LED_ON : LED_OFF);

    if (action.on) {
      ledMask.fetch_or(bit);
    } else {
      ledMask.fetch_and(~bit);
    }

    dirtyLeds.fetch_or(bit);

    Serial.printf("[LED] GPIO %d = %s\n", led.pin, action.on ? "ON" : "OFF");
  }
}

// --- Terima perintah MQTT ---
void queueBuzzerVolume(const char* data, int length) {
  if (length < 1 || length > 3) {
    return;
  }

  int volume = 0;
  for (int i = 0; i < length; i++) {
    if (data[i] < '0' || data[i] > '9') {
      return;
    }
    volume = volume * 10 + (data[i] - '0');
  }

  if (volume <= 100) {
    requestedVolume = volume;
  }
}

// MQTT mengirim topik dengan panjang eksplisit, tanpa penutup '\0'.
bool mqttMatches(const char* received, int length, const char* expected) {
  const size_t expectedLength = std::strlen(expected);
  return length == static_cast<int>(expectedLength) &&
         std::memcmp(received, expected, expectedLength) == 0;
}

void queueMqttAction(esp_mqtt_event_handle_t event) {
  if (event->retain || !event->topic || !event->data || event->current_data_offset != 0 ||
      event->data_len != event->total_data_len) {
    return;
  }

  if (mqttMatches(event->topic, event->topic_len, VOLUME_ACTION_TOPIC)) {
    queueBuzzerVolume(event->data, event->data_len);
    return;
  }

  const bool on = mqttMatches(event->data, event->data_len, "ON");
  const bool off = mqttMatches(event->data, event->data_len, "OFF");

  if (!on && !off) {
    Serial.println("[MQTT] Payload harus ON/OFF.");
    return;
  }

  const bool changesRelayMode = mqttMatches(event->topic, event->topic_len, RELAY_AUTO_ACTION);
  const bool changesRelayPower =
      mqttMatches(event->topic, event->topic_len, RELAY_SWITCH_ACTION);
  if (changesRelayMode || changesRelayPower) {
    // Satu antrean menjaga urutan perintah mode dan daya dari MQTT.
    RelayAction action{changesRelayMode, on};
    if (xQueueSend(relayQueue, &action, 0) != pdPASS) {
      Serial.println("[ERROR] Antrean relay penuh.");
    }
    return;
  }

  for (int i = 0; i < LED_COUNT; i++) {
    if (mqttMatches(event->topic, event->topic_len, leds[i].actionTopic)) {
      LedAction action{i, on};

      if (xQueueSend(actionQueue, &action, 0) != pdPASS) {
        Serial.println("[ERROR] Antrean LED penuh.");
      }

      return;
    }
  }
}

// --- Tangani kejadian MQTT ---
void onMqttEvent(void*, esp_event_base_t, int32_t eventId, void* eventData) {
  auto event = static_cast<esp_mqtt_event_handle_t>(eventData);

  static int ledSubscription = -1;
  static int otaSubscription = -1;
  static int volumeSubscription = -1;
  static int relayModeSubscription = -1;
  static int relayPowerSubscription = -1;

  switch (eventId) {
    case MQTT_EVENT_CONNECTED:
      Serial.println("[MQTT] CONNECTED");

      ledSubscription = esp_mqtt_client_subscribe(event->client, ACTION_FILTER, 1);

      otaSubscription = esp_mqtt_client_subscribe(event->client, FirmwareOta::FILTER, 1);

      volumeSubscription = esp_mqtt_client_subscribe(event->client, VOLUME_ACTION_TOPIC, 1);

      if (ledSubscription < 0 || otaSubscription < 0 || volumeSubscription < 0) {
        Serial.printf("[MQTT] SUBSCRIBE gagal: LED=%d OTA=%d BUZZER=%d\n", ledSubscription,
                      otaSubscription, volumeSubscription);
      }

      relayModeSubscription = esp_mqtt_client_subscribe(event->client, RELAY_AUTO_ACTION, 1);
      relayPowerSubscription = esp_mqtt_client_subscribe(event->client, RELAY_SWITCH_ACTION, 1);
      if (relayModeSubscription < 0 || relayPowerSubscription < 0) {
        Serial.printf("[MQTT] SUBSCRIBE relay gagal: mode=%d daya=%d\n", relayModeSubscription,
                      relayPowerSubscription);
      }

      syncState = true;
      mqttConnected = true;
      break;

    case MQTT_EVENT_SUBSCRIBED: {
      const char* filter = nullptr;
      if (event->msg_id == ledSubscription) {
        filter = ACTION_FILTER;
      } else if (event->msg_id == otaSubscription) {
        filter = FirmwareOta::FILTER;
      } else if (event->msg_id == volumeSubscription) {
        filter = VOLUME_ACTION_TOPIC;
      } else if (event->msg_id == relayModeSubscription) {
        filter = RELAY_AUTO_ACTION;
      } else if (event->msg_id == relayPowerSubscription) {
        filter = RELAY_SWITCH_ACTION;
      }

      if (filter) {
        const bool accepted =
            event->data && event->data_len == 1 && static_cast<uint8_t>(event->data[0]) <= 1;

        Serial.printf("[MQTT] SUBACK %s: %s\n", filter,
                      accepted ? "diterima" : "ditolak atau tidak valid");
      }
      break;
    }

    case MQTT_EVENT_DISCONNECTED:
      mqttConnected = false;
      Serial.println("[MQTT] DISCONNECTED - reconnect...");
      break;

    case MQTT_EVENT_DATA:
      if (!FirmwareOta::receive(event) && !FirmwareOta::isTransferring()) {
        queueMqttAction(event);
      }
      break;

    case MQTT_EVENT_ERROR:
      Serial.println("[MQTT] ERROR");

      if (event->error_handle) {
        const auto& error = *event->error_handle;

        Serial.printf(
            "[MQTT] type=%d TLS=0x%x "
            "mbedTLS=%d cert=0x%x "
            "socket=%d CONNACK=%d\n",
            static_cast<int>(error.error_type),
            static_cast<unsigned>(error.esp_tls_last_esp_err), error.esp_tls_stack_err,
            static_cast<unsigned>(error.esp_tls_cert_verify_flags),
            error.esp_transport_sock_errno, static_cast<int>(error.connect_return_code));
      }
      break;
  }
}

// --- Siapkan klien MQTT ---
void startMqtt() {
  Serial.println("[MQTT] Inisialisasi client...");

  // Siapkan koneksi MQTT terenkripsi dan pesan offline otomatis dari broker.
  esp_mqtt_client_config_t config{};

  config.broker.address.uri = MQTT_URI;
  config.broker.verification.certificate = MQTT_CA_PEM;

  config.credentials.client_id = CLIENT_ID;
  config.credentials.username = MQTT_USER;
  config.credentials.authentication.password = MQTT_PASSWORD;

  config.session.keepalive = 15;
  config.outbox.limit = 4096;
  config.buffer.size = FirmwareOta::CHUNK_SIZE + 256;
  config.buffer.out_size = 2048;

  config.session.last_will.topic = AVAILABILITY_TOPIC;

  config.session.last_will.msg = "offline";
  config.session.last_will.qos = 1;
  config.session.last_will.retain = true;

  mqtt = esp_mqtt_client_init(&config);

  if (!mqtt) {
    Serial.println("[ERROR] MQTT init gagal.");
    return;
  }

  if (esp_mqtt_client_register_event(mqtt, static_cast<esp_mqtt_event_id_t>(ESP_EVENT_ANY_ID),
                                     onMqttEvent, nullptr) != ESP_OK ||
      esp_mqtt_client_start(mqtt) != ESP_OK) {
    Serial.println("[ERROR] MQTT start gagal.");

    esp_mqtt_client_destroy(mqtt);
    mqtt = nullptr;
    return;
  }

  Serial.println("[MQTT] Client dimulai.");
}

// --- Sinkronkan waktu sebelum MQTT ---
void startMqttWhenReady() {
  static bool timeSyncStarted = false;
  static unsigned long lastStartAttempt = 0;

  if (mqtt || WiFi.status() != WL_CONNECTED) {
    return;
  }

  if (!timeSyncStarted) {
    Serial.println("[TLS] Sinkronisasi waktu NTP...");

    configTime(0, 0, "pool.ntp.org", "time.google.com");

    timeSyncStarted = true;
  }

  const unsigned long now = millis();

  if (std::time(nullptr) >= MIN_TLS_TIME &&
      (lastStartAttempt == 0 || now - lastStartAttempt >= 5000)) {
    Serial.println("[TLS] Waktu valid. Memulai MQTT.");

    lastStartAttempt = now;
    startMqtt();
  }
}

// --- Kirim status LED ---
void publishLedStates(bool resync) {
  if (resync) {
    dirtyLeds.fetch_or(ALL_LEDS);

    if (esp_mqtt_client_enqueue(mqtt, AVAILABILITY_TOPIC, "online", 0, 1, true, false) < 0) {
      syncState = true;
    }
  }

  const uint32_t pending = dirtyLeds.exchange(0);

  const uint32_t state = ledMask.load();

  for (int i = 0; i < LED_COUNT; i++) {
    const uint32_t bit = 1u << i;

    if ((pending & bit) == 0) {
      continue;
    }

    const char* payload = (state & bit) ? "ON" : "OFF";

    if (esp_mqtt_client_enqueue(mqtt, leds[i].stateTopic, payload, 0, 1, true, false) < 0) {
      dirtyLeds.fetch_or(bit);
    }
  }
}

// --- Format angka sensor ---
void formatMeasurement(char* buffer, size_t size, float value) {
  if (std::isfinite(value)) {
    snprintf(buffer, size, "%.1f", value);
  } else {
    snprintf(buffer, size, "null");
  }
}

// --- Periksa kondisi ruangan ---
void evaluateCondition(SensorReading& reading) {
  RoomRule rules[ROOM_RULE_COUNT];
  readRoomRules(reading, rules);

  for (int i = 0; i < ROOM_RULE_COUNT; i++) {
    const RoomRule& rule = rules[i];
    reading.ranges[i] = IN_RANGE;

    // Jika sensor gagal membaca, laporkan read_error lewat status sensor.
    if (!std::isfinite(rule.value)) {
      continue;
    }

    if (rule.value < rule.min) {
      reading.ranges[i] = BELOW_MIN;
    } else if (rule.value > rule.max) {
      reading.ranges[i] = ABOVE_MAX;
    }
  }
}

bool conditionChanged(const SensorReading& previous, const SensorReading& current) {
  if (previous.dhtOk != current.dhtOk || previous.bmpOk != current.bmpOk) {
    return true;
  }

  for (int i = 0; i < ROOM_RULE_COUNT; i++) {
    if (previous.ranges[i] != current.ranges[i]) {
      return true;
    }
  }

  return false;
}

bool isRoomNormal(const SensorReading& reading) {
  if (!reading.dhtOk || !reading.bmpOk) {
    return false;
  }

  for (int i = 0; i < ROOM_RULE_COUNT; i++) {
    if (reading.ranges[i] != IN_RANGE) {
      return false;
    }
  }

  return true;
}

// --- Baca sensor ---
// Baca suhu dan kelembapan dari satu pengukuran DHT.
void readDht(DHT& dht, SensorReading& reading) {
  reading.humidity = dht.readHumidity();
  reading.temperature = dht.readTemperature();

  if (!std::isfinite(reading.humidity) || !std::isfinite(reading.temperature)) {
    Serial.printf("[SENSOR] Baca DHT%d gagal, coba sekali lagi.\n", DHT_TYPE);
    vTaskDelay(pdMS_TO_TICKS(DHT_RETRY_MS));
    reading.humidity = dht.readHumidity(true);
    reading.temperature = dht.readTemperature();
  }

  reading.dhtOk = std::isfinite(reading.humidity) && std::isfinite(reading.temperature);
}

void readBmp(Adafruit_BMP085& bmp, bool& bmpReady, SensorReading& reading) {
  reading.bmpTemperature = NAN;
  reading.pressure = NAN;

  // Periksa apakah BMP180 masih merespons. Coba inisialisasi ulang jika terputus.
  if (bmpReady) {
    Wire.beginTransmission(BMP_ADDRESS);
    bmpReady = Wire.endTransmission() == 0;
  } else {
    bmpReady = bmp.begin();
  }

  if (bmpReady) {
    reading.bmpTemperature = bmp.readTemperature();

    const int32_t pressurePa = bmp.readPressure();

    if (pressurePa > 0) {
      reading.pressure = pressurePa / 100.0f;
    }

    reading.bmpOk = std::isfinite(reading.bmpTemperature) && std::isfinite(reading.pressure);
  }
}

void printSensorReading(const SensorReading& reading) {
  Serial.println();
  Serial.println("===== SENSOR READING =====");
  Serial.printf("DHT%d Temp: %.1f C\n", DHT_TYPE, reading.temperature);
  Serial.printf("DHT%d Hum : %.1f %%\n", DHT_TYPE, reading.humidity);
  Serial.printf("BMP Temp  : %.1f C\n", reading.bmpTemperature);
  Serial.printf("Pressure  : %.1f hPa\n", reading.pressure);
  Serial.printf("DHT Status: %s\n", reading.dhtOk ? "OK" : "ERROR");
  Serial.printf("BMP Status: %s\n", reading.bmpOk ? "OK" : "ERROR");
  Serial.println("==========================");
}

// Task ini menunggu jadwal sensor tanpa menahan task LED atau loop().
void runSensorTask(void*) {
  Serial.println("[SENSOR] Task berjalan.");

  DHT dht(DHT_PIN, DHT_TYPE);
  Adafruit_BMP085 bmp;

  Serial.printf("[SENSOR] Init DHT%d...\n", DHT_TYPE);
  dht.begin();

  Serial.println("[SENSOR] Init I2C...");
  Wire.begin(BMP_SDA, BMP_SCL);

  Serial.println("[SENSOR] Init BMP180...");
  bool bmpReady = bmp.begin();

  Serial.printf("[SENSOR] BMP180: %s\n", bmpReady ? "TERDETEKSI" : "TIDAK TERDETEKSI");

  TickType_t lastReadTick = xTaskGetTickCount();

  while (true) {
    vTaskDelayUntil(&lastReadTick, pdMS_TO_TICKS(READ_INTERVAL_MS));

    if (FirmwareOta::isTransferring()) {
      continue;
    }

    SensorReading reading{};

    readDht(dht, reading);
    if (FirmwareOta::isTransferring()) {
      continue;
    }
    readBmp(bmp, bmpReady, reading);
    evaluateCondition(reading);

    xQueueOverwrite(latestReading, &reading);

    printSensorReading(reading);
  }
}

// --- Kirim hasil pengukuran ---
void publishTelemetry(const SensorReading& reading) {
  // Pertahankan kunci JSON dht22 agar dashboard tetap bisa membaca status.
  char temperatureText[16];
  char humidityText[16];
  char pressureText[16];
  char bmpTemperatureText[16];

  formatMeasurement(temperatureText, sizeof(temperatureText), reading.temperature);

  formatMeasurement(humidityText, sizeof(humidityText), reading.humidity);

  formatMeasurement(pressureText, sizeof(pressureText), reading.pressure);

  formatMeasurement(bmpTemperatureText, sizeof(bmpTemperatureText), reading.bmpTemperature);

  char json[336];

  snprintf(json, sizeof(json),
           "{\"temperature_c\":%s,"
           "\"humidity_pct\":%s,"
           "\"pressure_hpa\":%s,"
           "\"bmp_temperature_c\":%s,"
           "\"sensor_status\":{"
           "\"dht22\":\"%s\","
           "\"bmp180\":\"%s\"},"
           "\"build_id\":\"%s\"}",
           temperatureText, humidityText, pressureText, bmpTemperatureText,
           reading.dhtOk ? "ok" : "read_error", reading.bmpOk ? "ok" : "read_error",
           FirmwareOta::buildId);

  if (esp_mqtt_client_enqueue(mqtt, TELEMETRY_TOPIC, json, 0, 0, false, true) < 0) {
    Serial.println("[MQTT] Telemetry enqueue gagal.");
  } else {
    Serial.print("[TELEMETRY] ");
    Serial.println(json);
  }
}

// --- Kirim status ruangan ---
// Tambahkan satu objek ke daftar issues dan sisakan ruang untuk "]}".
bool appendIssue(char* payload, size_t capacity, size_t& used, bool& needsComma,
                 const char* detail) {
  const size_t length = strlen(detail);
  const size_t commaLength = needsComma ? 1 : 0;
  if (used + commaLength + length + 3 > capacity) {
    return false;
  }

  if (needsComma) {
    payload[used++] = ',';
  }
  memcpy(payload + used, detail, length);
  used += length;
  needsComma = true;
  return true;
}

bool publishCondition(const SensorReading& reading) {
  char payload[512];

  size_t used = snprintf(payload, sizeof(payload), "{\"condition\":\"%s\",\"issues\":[",
                         isRoomNormal(reading) ? "normal" : "abnormal");

  bool needsComma = false;

  RoomRule rules[ROOM_RULE_COUNT];
  readRoomRules(reading, rules);

  for (size_t i = 0; i < ROOM_RULE_COUNT; i++) {
    const RangeStatus range = reading.ranges[i];

    if (range == IN_RANGE) {
      continue;
    }

    const RoomRule& rule = rules[i];

    char detail[160];

    const int count = snprintf(detail, sizeof(detail),
                               "{\"parameter\":\"%s\","
                               "\"value\":%.1f,"
                               "\"min\":%.1f,"
                               "\"max\":%.1f,"
                               "\"reason\":\"%s\"}",
                               rule.parameter, rule.value, rule.min, rule.max,
                               range == BELOW_MIN ? "below_min" : "above_max");

    if (count < 0 || static_cast<size_t>(count) >= sizeof(detail) ||
        !appendIssue(payload, sizeof(payload), used, needsComma, detail)) {
      return false;
    }
  }

  if (!reading.dhtOk && !appendIssue(payload, sizeof(payload), used, needsComma,
                                     "{\"sensor\":\"dht22\","
                                     "\"reason\":\"read_error\"}")) {
    return false;
  }

  if (!reading.bmpOk && !appendIssue(payload, sizeof(payload), used, needsComma,
                                     "{\"sensor\":\"bmp180\","
                                     "\"reason\":\"read_error\"}")) {
    return false;
  }

  memcpy(payload + used, "]}", 3);

  return esp_mqtt_client_enqueue(mqtt, CONDITION_TOPIC, payload, 0, 1, true, false) >= 0;
}

// --- Alarm lokal dan laporan level buzzer ---
void serviceBuzzer(bool abnormal, bool connected, bool resync, bool paused) {
  static int lastPotLevel = -1;
  static int volume = 0;
  static bool volumePending = true;
  static bool buzzerOn = false;
  static bool alarmRunning = false;
  static unsigned long lastBuzzerChange = 0;

  if (paused) {
    if (buzzerOn) {
      digitalWrite(BUZZER_PIN, BUZZER_OFF);
    }
    buzzerOn = false;
    alarmRunning = false;
    return;
  }

  // Toleransi kecil di ujung ADC agar posisi minimum bisa benar-benar diam.
  const int potSample = analogRead(POT_PIN);
  const int potRaw = constrain(potSample, 80, 4015);
  const int potLevel = map(potRaw, 80, 4015, 0, 100);
  const bool potMoved = lastPotLevel < 0 ||
                        abs(potLevel - lastPotLevel) >= POT_CHANGE_THRESHOLD ||
                        (potLevel != lastPotLevel && (potLevel == 0 || potLevel == 100));
  if (potMoved) {
    lastPotLevel = potLevel;
    volume = potLevel;
    volumePending = true;
  }

  // Jika perintah tiba pada putaran yang sama, perintah MQTT didahulukan.
  const int command = requestedVolume.exchange(-1);
  if (command >= 0) {
    volume = command;
    lastPotLevel = potLevel;
    volumePending = true;
  }

  const unsigned long now = millis();
  if (!abnormal || volume == 0) {
    if (buzzerOn) {
      digitalWrite(BUZZER_PIN, BUZZER_OFF);
    }
    buzzerOn = false;
    alarmRunning = false;
  } else {
    // Pada buzzer aktif, level mengubah jeda antarbip, dari 2 detik ke 100 ms.
    const unsigned long pauseMs = map(volume, 1, 100, 2000, 100);
    const unsigned long interval = buzzerOn ? BEEP_MS : pauseMs;
    if (!alarmRunning || now - lastBuzzerChange >= interval) {
      alarmRunning = true;
      buzzerOn = !buzzerOn;
      digitalWrite(BUZZER_PIN, buzzerOn ? BUZZER_ON : BUZZER_OFF);
      lastBuzzerChange = now;
    }
  }

  if (resync) {
    volumePending = true;
  }
  if (connected && volumePending) {
    char payload[4];
    snprintf(payload, sizeof(payload), "%d", volume);
    volumePending =
        esp_mqtt_client_enqueue(mqtt, VOLUME_STATE_TOPIC, payload, 0, 1, true, false) < 0;
  }
}

// --- Kontrol relay kipas ---
void serviceRelay(bool tooHot, bool connected, bool resync) {
  static bool automatic = false;
  static bool manualOn = false;
  static bool relayOn = false;
  static bool modePending = true;
  static bool powerPending = true;

  // Batasi pekerjaan setiap putaran agar MQTT dan OTA tetap dilayani.
  for (int i = 0; i < 8; i++) {
    RelayAction action{};
    if (!relayQueue || xQueueReceive(relayQueue, &action, 0) != pdPASS) {
      break;
    }

    if (action.changesMode) {
      if (automatic && !action.on) {
        manualOn = false;
      }
      automatic = action.on;
      modePending = true;
    } else {
      if (!automatic) {
        manualOn = action.on;
      }
      // Dalam mode otomatis, balas dengan status daya yang sebenarnya.
      powerPending = true;
    }
  }

  const bool shouldTurnOn = automatic ? tooHot : manualOn;
  if (shouldTurnOn != relayOn) {
    relayOn = shouldTurnOn;
    digitalWrite(RELAY_PIN, relayOn ? RELAY_ON : RELAY_OFF);
    powerPending = true;
  }

  if (resync) {
    modePending = true;
    powerPending = true;
  }

  if (!connected) {
    return;
  }

  if (modePending) {
    modePending = esp_mqtt_client_enqueue(mqtt, RELAY_AUTO_STATE, automatic ? "ON" : "OFF", 0,
                                          1, true, false) < 0;
  }
  if (powerPending) {
    powerPending = esp_mqtt_client_enqueue(mqtt, RELAY_SWITCH_STATE, relayOn ? "ON" : "OFF", 0,
                                           1, true, false) < 0;
  }
}

// --- Persiapan perangkat dan Wi-Fi ---
// Mulai koneksi. Statusnya dicek di loop() sambil bagian lain tetap berjalan.
void connectWiFi() {
  Serial.println("[BOOT] Setup WiFi...");

  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);

  const char* ssid = RUN_IN_WOKWI ? "Wokwi-GUEST" : HOME_WIFI_SSID;

  const char* password = RUN_IN_WOKWI ? "" : HOME_WIFI_PASSWORD;

  Serial.printf("[WIFI] Menghubungkan ke: %s\n", ssid);

  WiFi.begin(ssid, password);
}

void setup() {
  // Serial diinisialisasi paling awal.
  digitalWrite(RELAY_PIN, RELAY_OFF);
  pinMode(RELAY_PIN, OUTPUT);
  digitalWrite(RELAY_PIN, RELAY_OFF);
  pinMode(BUZZER_PIN, OUTPUT);
  digitalWrite(BUZZER_PIN, BUZZER_OFF);

  Serial.begin(115200);
  delay(2000);

  printSystemInfo();

  Serial.println("[BOOT] Mulai setup...");

  // LED
  Serial.println("[BOOT] Setup LED...");

  for (const Led& led : leds) {
    pinMode(led.pin, OUTPUT);
    digitalWrite(led.pin, LED_OFF);
  }

  Serial.println("[BOOT] LED siap.");

  // OTA
  Serial.println("[BOOT] Setup OTA...");
  Serial.flush();

  FirmwareOta::setup();

  Serial.println("[BOOT] OTA setup selesai.");
  Serial.flush();

  // Antrean memisahkan proses MQTT, LED, dan pembacaan sensor.
  Serial.println("[BOOT] Membuat queue...");

  actionQueue = xQueueCreate(16, sizeof(LedAction));

  relayQueue = xQueueCreate(8, sizeof(RelayAction));

  latestReading = xQueueCreate(1, sizeof(SensorReading));

  if (!actionQueue || !relayQueue || !latestReading) {
    Serial.println("[FATAL] Queue gagal dibuat.");
    Serial.flush();
    return;
  }

  Serial.println("[BOOT] Queue berhasil.");

  // Sensor dan LED berjalan dengan jadwal masing-masing.
  Serial.println("[BOOT] Membuat LED task...");

  BaseType_t ledTaskResult = xTaskCreate(runLedTask, "LED", 3072, nullptr, 2, nullptr);

  Serial.println("[BOOT] Membuat Sensor task...");

  BaseType_t sensorTaskResult =
      xTaskCreate(runSensorTask, "Sensors", 4096, nullptr, 1, nullptr);

  if (ledTaskResult != pdPASS || sensorTaskResult != pdPASS) {
    Serial.println("[FATAL] FreeRTOS task gagal.");

    Serial.flush();
    return;
  }

  Serial.println("[BOOT] FreeRTOS siap.");

  connectWiFi();

  Serial.println("[BOOT] Setup selesai.");
  Serial.println("[BOOT] Masuk main loop.");
  Serial.flush();
}

// --- Jalankan MQTT dan OTA ---
void loop() {
  static SensorReading current{};
  static bool hasReading = false;
  static bool conditionPending = false;

  static unsigned long lastDebug = 0;
  static bool previousWifiConnected = false;

  const bool wifiConnected = WiFi.status() == WL_CONNECTED;

  if (wifiConnected != previousWifiConnected) {
    if (wifiConnected) {
      Serial.println("[WIFI] CONNECTED");

      Serial.print("[WIFI] IP: ");
      Serial.println(WiFi.localIP());
      Serial.printf("[WIFI] RSSI: %d dBm\n", WiFi.RSSI());
    } else {
      Serial.println("[WIFI] DISCONNECTED");
    }

    previousWifiConnected = wifiConnected;
  }

  startMqttWhenReady();

  static bool syncAfterOta = false;
  const bool connected = mqttConnected.load();
  const bool mqttResync = connected && syncState.exchange(false);
  FirmwareOta::service(mqtt, connected, mqttResync);

  if (FirmwareOta::isTransferring()) {
    // Saat OTA, pertahankan LED dan relay, serta bisukan buzzer.
    syncAfterOta = true;
    serviceBuzzer(false, false, false, true);
    delay(1);
    return;
  }

  const bool resync = connected && (mqttResync || syncAfterOta);
  if (resync) {
    syncAfterOta = false;
  }

  SensorReading reading{};

  const bool newReading = latestReading && xQueueReceive(latestReading, &reading, 0) == pdPASS;

  if (newReading) {
    if (!hasReading || conditionChanged(current, reading)) {
      conditionPending = true;
    }

    current = reading;
    hasReading = true;
  }

  const bool tooHot =
      hasReading && current.dhtOk && current.ranges[TEMPERATURE_RULE] == ABOVE_MAX;
  serviceRelay(tooHot, connected, resync);
  serviceBuzzer(hasReading && !isRoomNormal(current), connected, resync, false);

  if (connected) {
    // Saat MQTT tersambung kembali, kirim keadaan terkini ke dashboard.
    publishLedStates(resync);

    if (hasReading && (newReading || resync)) {
      publishTelemetry(current);
    }

    if (resync) {
      conditionPending = true;
    }

    if (hasReading && conditionPending && (newReading || resync)) {
      conditionPending = !publishCondition(current);
    }
  }

  // Gunakan waktu yang sama untuk jadwal dan laporan uptime.
  const unsigned long now = millis();
  if (now - lastDebug >= READ_INTERVAL_MS) {
    lastDebug = now;

    Serial.println();
    Serial.println("===== ESP32 STATUS =====");
    Serial.printf("Uptime : %lu detik\n", now / 1000);
    Serial.printf("Heap   : %u bytes\n", ESP.getFreeHeap());
    Serial.printf("WiFi   : %s\n", wifiConnected ? "CONNECTED" : "DISCONNECTED");
    Serial.printf("MQTT   : %s\n", connected ? "CONNECTED" : "DISCONNECTED");
    Serial.println("========================");
  }

  delay(50);
}
