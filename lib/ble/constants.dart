const String kDeviceName = 'EPD-C6';
const String kServiceUuid = '7b1e0001-5f5c-4a1a-9c3e-6f2d8a0b0001';
const String kStatusCharUuid = '7b1e0002-5f5c-4a1a-9c3e-6f2d8a0b0001';
const String kCmdCharUuid = '7b1e0003-5f5c-4a1a-9c3e-6f2d8a0b0001';

const int kCmdMaxLen = 63;
const int kGroupMinLen = 2;
const int kGroupMaxLen = 5;
const int kPairsMax = 8;

const List<String> kPresetLetters = ['A', 'B', 'C', 'D', 'E', 'F', 'G'];
const List<String> kPairOrderDigits = ['1', '2', '3', '4', '5', '6', '7'];
const String kStandbyWord = 'THINK';

const int kMaxSsidBytes = 32;
const int kMaxPassBytes = 63;
const int kBleChunkBytes = 16;
const int kPreferredBleMtu = 185;
const String kDefaultHost = 'epd-c6.local';

const Duration kScanTimeout = Duration(seconds: 12);
const Duration kProvisionTimeout = Duration(seconds: 18);
const Duration kHttpTimeout = Duration(seconds: 6);
const Duration kWebConnectTimeout = Duration(seconds: 25);
const Duration kRenderPollInterval = Duration(milliseconds: 900);
const int kHistoryMax = 20;
