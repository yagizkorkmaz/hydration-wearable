// Hydration Monitoring Wearable - ESP32-S3 firmware
//
// Reads GSR (ADC), MAX30102 PPG (red + IR) and SHT31 temperature/humidity,
// shows live values on an SSD1315 OLED and streams one CSV packet every
// 200 ms over BLE (Nordic UART service):
//
//   timestamp,gsr,red,ir,temp,humidity
//
// Arduino IDE: board "ESP32S3 Dev Module", Tools -> USB CDC On Boot: Enabled.

#include <Arduino.h>
#include <Wire.h>

// =====================================================
// OLED - SSD1315
// =====================================================
#include <U8g2lib.h>

// =====================================================
// SENSORLER
// =====================================================
#include "MAX30105.h"
#include <Adafruit_SHT31.h>

// =====================================================
// BLE
// =====================================================
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>


// =====================================================
// PINLER
// =====================================================

#define SDA_PIN 8
#define SCL_PIN 9

#define GSR_PIN 4

// Eski kodda power button olarak kullaniliyordu.
// Bu surumde SADECE OKUNUYOR, hicbir sey tetiklemiyor.
// Heartbeat satirinda durumunu gormek icin duruyor:
// LOW gorunuyorsa eski kodun neden uykuya daldigi
// anlasilmis olur.
#define OLD_POWER_PIN 5


// =====================================================
// SSD1315 OLED
// =====================================================

U8G2_SSD1315_128X64_NONAME_F_HW_I2C u8g2(
  U8G2_R0,
  U8X8_PIN_NONE,
  SCL_PIN,
  SDA_PIN
);

bool oledOK = false;
uint8_t oledAddress = 0x3C;


// =====================================================
// BLE
// =====================================================

#define DEVICE_NAME "HydrationSensor"

// MOBIL UYGULAMADAKI SERVICE UUID AYNI
#define SERVICE_UUID \
"6E400001-B5A3-F393-E0A9-E50E24DCCA9E"

// MOBIL UYGULAMADAKI TX UUID AYNI
#define TX_CHARACTERISTIC_UUID \
"6E400003-B5A3-F393-E0A9-E50E24DCCA9E"


BLEServer* pServer = nullptr;
BLECharacteristic* pTxCharacteristic = nullptr;

volatile bool deviceConnected = false;

// Baglanti koptuktan sonra yeniden advertise etmek icin.
// onDisconnect callback'i BLE stack'inin kendi task'inda
// calisir; orada agir is yapmayip loop()'a bayrak birakiyoruz.
volatile bool advertiseRestartPending = false;
volatile unsigned long disconnectedAt = 0;

// GUVENLIK AGI: bagli degilken periyodik olarak advertising'i
// tekrar tetikle. Stack herhangi bir sebeple advertising'i
// birakirsa (kopma sirasindaki yaris durumu, ic hata) cihaz
// kalici olarak gorunmez hale gelmesin.
const unsigned long ADVERTISE_KICK_INTERVAL = 10000;
unsigned long lastAdvertiseKick = 0;


// =====================================================
// SENSORLER
// =====================================================

MAX30105 maxSensor;
Adafruit_SHT31 sht31 = Adafruit_SHT31();

bool maxOK = false;
bool shtOK = false;


// =====================================================
// SENSOR DEGERLERI
// =====================================================

int latestGSR = 0;

uint32_t latestRed = 0;
uint32_t latestIR = 0;

float latestTemperature = 0.0;
float latestHumidity = 0.0;


// =====================================================
// ZAMANLAMALAR
// =====================================================

// BLE FORMATI VE GONDERIM HIZI DEGISMEDI
const unsigned long SEND_INTERVAL = 200;
unsigned long lastSend = 0;

const unsigned long SHT_INTERVAL = 1000;
unsigned long lastSHTRead = 0;

const unsigned long DISPLAY_INTERVAL = 200;
unsigned long lastDisplayUpdate = 0;

// Bagli degilken durum satiri
const unsigned long HEARTBEAT_INTERVAL = 5000;
unsigned long lastHeartbeat = 0;


// =====================================================
// BLE CALLBACK
// =====================================================

class MyServerCallbacks : public BLEServerCallbacks {

  void onConnect(BLEServer* pServer) {
    deviceConnected = true;

    advertiseRestartPending = false;

    Serial.println();
    Serial.println("BLE: TELEFON BAGLANDI");
  }

  void onDisconnect(BLEServer* pServer) {
    deviceConnected = false;

    // Kopma aninda hemen advertise etmeye calismak
    // stack'te yaris durumuna yol acabiliyor; loop()
    // 500 ms sonra baslatacak.
    advertiseRestartPending = true;
    disconnectedAt = millis();

    Serial.println();
    Serial.println("BLE: TELEFON AYRILDI");
  }
};


// =====================================================
// BLE BASLAT
//
// !!! setup()'IN EN BASINDA CAGRILIYOR !!!
//
// Sensorler tamamen bozuk olsa bile cihaz advertise
// etmeye devam eder.
// =====================================================

void setupBLE() {

  Serial.println();
  Serial.println("BLE baslatiliyor...");


  BLEDevice::init(DEVICE_NAME);


  // Veri stringimiz 20 byte'tan uzun olabilir.
  // VERI FORMATINI DEGISTIRMEZ.
  BLEDevice::setMTU(100);


  pServer = BLEDevice::createServer();

  pServer->setCallbacks(new MyServerCallbacks());


  BLEService* pService =
    pServer->createService(SERVICE_UUID);


  pTxCharacteristic =
    pService->createCharacteristic(

      TX_CHARACTERISTIC_UUID,

      BLECharacteristic::PROPERTY_NOTIFY |
      BLECharacteristic::PROPERTY_READ

    );


  pTxCharacteristic->addDescriptor(new BLE2902());


  pService->start();


  // ---------------------------------------------------
  // ADVERTISING
  // ---------------------------------------------------

  BLEAdvertising* pAdvertising =
    BLEDevice::getAdvertising();


  pAdvertising->addServiceUUID(SERVICE_UUID);


  // Cihaz adi scan response'a gider.
  pAdvertising->setScanResponse(true);


  // iOS'un baglanti araligini kabul etmesi icin
  pAdvertising->setMinPreferred(0x06);
  pAdvertising->setMaxPreferred(0x12);


  BLEDevice::startAdvertising();


  Serial.println("==============================");
  Serial.print("BLE HAZIR -> ");
  Serial.println(DEVICE_NAME);
  Serial.println("==============================");
}


// =====================================================
// I2C CIHAZ KONTROL
// =====================================================

bool i2cExists(uint8_t address) {

  Wire.beginTransmission(address);

  uint8_t result = Wire.endTransmission();

  return result == 0;
}


// =====================================================
// I2C SCANNER
// =====================================================

void scanI2C() {

  Serial.println();
  Serial.println("==============================");
  Serial.println("I2C SCAN");
  Serial.println("==============================");

  int found = 0;

  for (uint8_t address = 1; address < 127; address++) {

    Wire.beginTransmission(address);

    uint8_t error = Wire.endTransmission();

    if (error == 0) {

      Serial.print("I2C cihaz bulundu: 0x");

      if (address < 16) {
        Serial.print("0");
      }

      Serial.println(address, HEX);

      found++;
    }
  }

  Serial.println("------------------------------");

  if (found == 0) {
    Serial.println("HIC I2C CIHAZI BULUNAMADI!");
  }
  else {
    Serial.print("Toplam I2C cihaz: ");
    Serial.println(found);
  }

  Serial.println("==============================");
}


// =====================================================
// OLED BASLAT
// =====================================================

void setupOLED() {

  Serial.println();
  Serial.print("OLED SSD1315: ");


  if (i2cExists(0x3C)) {
    oledAddress = 0x3C;
  }
  else if (i2cExists(0x3D)) {
    oledAddress = 0x3D;
  }
  else {
    oledOK = false;
    Serial.println("BULUNAMADI");
    return;
  }


  Serial.print("0x");
  Serial.println(oledAddress, HEX);


  // U8g2 adresi 8-bit format bekliyor: 0x3C << 1 = 0x78
  u8g2.setI2CAddress(oledAddress << 1);

  u8g2.setBusClock(400000);

  u8g2.begin();

  u8g2.setPowerSave(0);

  oledOK = true;


  u8g2.clearBuffer();

  u8g2.setFont(u8g2_font_6x10_tf);

  u8g2.drawStr(0, 15, "HydrationSensor");
  u8g2.drawStr(0, 32, "SSD1315 OK");
  u8g2.drawStr(0, 48, "Baslatiliyor...");

  u8g2.sendBuffer();


  Serial.println("OLED BASLATILDI");
}


// =====================================================
// OLED GUNCELLE
// =====================================================

void updateDisplay() {

  if (!oledOK) {
    return;
  }


  u8g2.clearBuffer();

  u8g2.setFont(u8g2_font_6x10_tf);


  u8g2.setCursor(0, 10);
  u8g2.print("GSR : ");
  u8g2.print(latestGSR);


  u8g2.setCursor(0, 20);
  u8g2.print("RED : ");

  if (maxOK) {
    u8g2.print((unsigned long)latestRed);
  }
  else {
    u8g2.print("ERR");
  }


  u8g2.setCursor(0, 30);
  u8g2.print("IR  : ");

  if (maxOK) {
    u8g2.print((unsigned long)latestIR);
  }
  else {
    u8g2.print("ERR");
  }


  u8g2.setCursor(0, 40);
  u8g2.print("TEMP: ");

  if (shtOK) {
    u8g2.print(latestTemperature, 1);
    u8g2.print(" C");
  }
  else {
    u8g2.print("ERR");
  }


  u8g2.setCursor(0, 50);
  u8g2.print("HUM : ");

  if (shtOK) {
    u8g2.print(latestHumidity, 1);
    u8g2.print(" %");
  }
  else {
    u8g2.print("ERR");
  }


  u8g2.setCursor(0, 62);
  u8g2.print("BLE : ");

  if (deviceConnected) {
    u8g2.print("CONNECTED");
  }
  else {
    u8g2.print("WAITING");
  }


  u8g2.sendBuffer();
}


// =====================================================
// SETUP
// =====================================================

void setup() {

  Serial.begin(115200);

  delay(1000);


  Serial.println();
  Serial.println();
  Serial.println("==============================");
  Serial.println("HYDRATION SENSOR");
  Serial.println("ESP32-S3");
  Serial.println("UYKU: TAMAMEN KAPALI");
  Serial.println("==============================");


  // ===================================================
  // 1) ONCE BLE
  //
  // Sensorlerden BAGIMSIZ olsun diye en basta.
  // ===================================================

  setupBLE();


  // ===================================================
  // 2) ESKI POWER PIN - SADECE TESHIS
  //
  // Hicbir sey tetiklemiyor. LOW gorunuyorsa eski
  // kodun neden 2 saniyede uykuya daldigi anlasilir.
  // ===================================================

  pinMode(OLD_POWER_PIN, INPUT_PULLUP);

  delay(20);

  Serial.print("GPIO");
  Serial.print(OLD_POWER_PIN);
  Serial.print(" (eski power pin) okumasi: ");
  Serial.println(
    digitalRead(OLD_POWER_PIN) == LOW
      ? "LOW  <-- eski kod bu yuzden uyuyordu"
      : "HIGH (normal)"
  );


  // ===================================================
  // 3) GSR
  // ===================================================

  analogReadResolution(12);

  pinMode(GSR_PIN, INPUT);

  Serial.print("GSR GPIO: ");
  Serial.println(GSR_PIN);


  // ===================================================
  // 4) I2C
  // ===================================================

  Wire.begin(SDA_PIN, SCL_PIN);

  Wire.setClock(400000);

  // Hatali kablolamada I2C sonsuza kadar beklemesin.
  Wire.setTimeOut(50);


  Serial.print("I2C SDA: GPIO");
  Serial.println(SDA_PIN);

  Serial.print("I2C SCL: GPIO");
  Serial.println(SCL_PIN);


  scanI2C();


  // ===================================================
  // 5) OLED
  // ===================================================

  setupOLED();


  // ===================================================
  // 6) MAX30102
  // ===================================================

  Serial.println();
  Serial.print("MAX30102: ");


  if (maxSensor.begin(Wire, I2C_SPEED_FAST)) {

    maxOK = true;

    Serial.println("BULUNDU");


    // brightness=0x1F, avg=4, mode=2 (RED+IR),
    // 100 Hz, 411 us, adc 4096
    maxSensor.setup(0x1F, 4, 2, 100, 411, 4096);

    Serial.println("MAX30102 RED + IR aktif");
  }

  else {

    maxOK = false;

    Serial.println("BULUNAMADI");
  }


  // ===================================================
  // 7) SHT31
  // ===================================================

  Serial.print("SHT31: ");


  if (sht31.begin(0x44)) {

    shtOK = true;

    Serial.println("BULUNDU @ 0x44");
  }

  else if (sht31.begin(0x45)) {

    shtOK = true;

    Serial.println("BULUNDU @ 0x45");
  }

  else {

    shtOK = false;

    Serial.println("BULUNAMADI");
  }


  // ===================================================
  // ILK OKUMALAR
  // ===================================================

  if (shtOK) {

    float temp = sht31.readTemperature();
    float hum  = sht31.readHumidity();

    if (!isnan(temp)) {
      latestTemperature = temp;
    }

    if (!isnan(hum)) {
      latestHumidity = hum;
    }
  }


  latestGSR = analogRead(GSR_PIN);


  // ===================================================
  // OZET
  // ===================================================

  Serial.println();
  Serial.println("==============================");
  Serial.println("SISTEM HAZIR");
  Serial.println("==============================");

  Serial.print("OLED     : ");
  Serial.println(oledOK ? "OK" : "YOK");

  Serial.print("MAX30102 : ");
  Serial.println(maxOK ? "OK" : "YOK");

  Serial.print("SHT31    : ");
  Serial.println(shtOK ? "OK" : "YOK");

  Serial.println("Format:");
  Serial.println("timestamp,gsr,red,ir,temp,humidity");

  Serial.println("==============================");


  updateDisplay();
}


// =====================================================
// LOOP
// =====================================================

void loop() {


  // ===================================================
  // GSR
  // ===================================================

  latestGSR = analogRead(GSR_PIN);


  // ===================================================
  // MAX30102
  // ===================================================

  if (maxOK) {

    maxSensor.check();

    while (maxSensor.available()) {

      latestRed = maxSensor.getFIFORed();

      latestIR = maxSensor.getFIFOIR();

      maxSensor.nextSample();
    }
  }


  // ===================================================
  // SHT31
  // ===================================================

  if (
    shtOK &&
    millis() - lastSHTRead >= SHT_INTERVAL
  ) {

    lastSHTRead = millis();


    float temp = sht31.readTemperature();
    float hum  = sht31.readHumidity();

    if (!isnan(temp)) {
      latestTemperature = temp;
    }

    if (!isnan(hum)) {
      latestHumidity = hum;
    }
  }


  // ===================================================
  // OLED
  // ===================================================

  if (
    millis() - lastDisplayUpdate >= DISPLAY_INTERVAL
  ) {

    lastDisplayUpdate = millis();

    updateDisplay();
  }


  // ===================================================
  // BLE VERISI
  //
  // MOBIL UYGULAMANIN BEKLEDIGI FORMAT DEGISMEDI:
  // timestamp,gsr,red,ir,temp,humidity
  // Ornek: 15240,1874,84231,91342,24.63,46.18
  // ===================================================

  if (
    deviceConnected &&
    millis() - lastSend >= SEND_INTERVAL
  ) {

    lastSend = millis();


    String data =

      String(millis()) + "," +

      String(latestGSR) + "," +

      String((unsigned long)latestRed) + "," +

      String((unsigned long)latestIR) + "," +

      String(latestTemperature, 2) + "," +

      String(latestHumidity, 2);


    pTxCharacteristic->setValue(data.c_str());

    pTxCharacteristic->notify();

    Serial.println(data);
  }


  // ===================================================
  // BAGLI DEGILKEN: YASIYORUM SATIRI
  //
  // Bu satiri goruyorsan ESP ayakta ve advertise
  // ediyor demektir. nRF Connect hala gormuyorsa
  // sorun ESP'nin calismasinda degildir.
  // ===================================================

  if (
    !deviceConnected &&
    millis() - lastHeartbeat >= HEARTBEAT_INTERVAL
  ) {

    lastHeartbeat = millis();


    Serial.print("[");
    Serial.print(millis() / 1000);
    Serial.print("s] advertise -> ");
    Serial.print(DEVICE_NAME);

    Serial.print(" | GPIO");
    Serial.print(OLD_POWER_PIN);
    Serial.print("=");
    Serial.print(digitalRead(OLD_POWER_PIN) == LOW ? "LOW" : "HIGH");

    Serial.print(" | GSR=");
    Serial.print(latestGSR);

    Serial.print(" RED=");
    Serial.print((unsigned long)latestRed);

    Serial.print(" IR=");
    Serial.print((unsigned long)latestIR);

    Serial.print(" T=");
    Serial.print(latestTemperature, 2);

    Serial.print(" H=");
    Serial.println(latestHumidity, 2);
  }


  // ===================================================
  // BAGLANTI KOPTUKTAN SONRA YENIDEN ADVERTISE
  //
  // Eski kodda bu blok delay(500) ile loop'u
  // blokluyordu ve yalnizca BIR KEZ calisiyordu.
  // Advertising herhangi bir sebeple baslamazsa cihaz
  // bir daha asla gorunmuyordu -- "bir kere kopunca
  // tekrar baglanamiyor" sikayetinin sebebi buydu.
  //
  // Artik bloklamiyor ve asagidaki guvenlik agi ile
  // periyodik olarak tekrar deneniyor.
  // ===================================================

  if (!deviceConnected) {

    if (
      advertiseRestartPending &&
      millis() - disconnectedAt >= 500
    ) {

      advertiseRestartPending = false;

      BLEDevice::startAdvertising();

      lastAdvertiseKick = millis();

      Serial.println("BLE tekrar advertise ediliyor...");
    }


    // ---------------------------------------------------
    // GUVENLIK AGI
    //
    // Bagli degilken 10 saniyede bir advertising'i
    // yeniden tetikle. Zaten calisiyorsa zararsizdir.
    // ---------------------------------------------------

    else if (
      !advertiseRestartPending &&
      millis() - lastAdvertiseKick >= ADVERTISE_KICK_INTERVAL
    ) {

      lastAdvertiseKick = millis();

      BLEDevice::startAdvertising();
    }
  }
}
