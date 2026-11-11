const String kDeviceName = 'EPD-C6';
const String kServiceUuid = '7b1e0001-5f5c-4a1a-9c3e-6f2d8a0b0001';
const String kStatusCharUuid = '7b1e0002-5f5c-4a1a-9c3e-6f2d8a0b0001';
const String kCmdCharUuid = '7b1e0003-5f5c-4a1a-9c3e-6f2d8a0b0001';

const int kCmdMaxLen = 63;
const int kGroupMinLen = 2;
const int kGroupMaxLen = 5;
const int kPairsMax = 8;

const Duration kScanTimeout = Duration(seconds: 12);
const Duration kUpdateTimeout = Duration(seconds: 4);
const int kHistoryMax = 20;
