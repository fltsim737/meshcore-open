import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/usb_serial_service_native.dart';

void main() {
  // flserial's port list: "port - description - hardware id"
  const linux = [
    '/dev/ttyS0 - n/a - n/a',
    '/dev/ttyUSB0 - CP2102 USB to UART Bridge Controller - USB VID:PID=10c4:ea60 SNR=0001',
    '/dev/ttyACM0 - RAK4631 - USB VID:PID=239a:8029 SNR=ABC',
  ];
  const windows = [
    r'COM5 - Silicon Labs CP210x USB to UART Bridge (COM5) - USB\VID_10C4&PID_EA60&REV_0100',
    r'COM7 - USB-SERIAL CH340 (COM7) - USB\VID_1A86&PID_7523&REV_0264',
    r'COM9 - USB Serial Device (COM9) - USB\VID_239A&PID_8029&MI_00',
  ];

  test('a CP210x or CH340 bridge is one: DTR and RTS stay off (the Heltec PRG button)', () {
    expect(isUartBridgePort('/dev/ttyUSB0', linux), isTrue);
    expect(isUartBridgePort('COM5', windows), isTrue);
    expect(isUartBridgePort('COM7', windows), isTrue);
  });

  test('a native USB board (nRF52) is not: it keeps its DTR handshake', () {
    expect(isUartBridgePort('/dev/ttyACM0', linux), isFalse);
    expect(isUartBridgePort('COM9', windows), isFalse);
  });

  test('an unknown or unlisted port is not', () {
    expect(isUartBridgePort('/dev/ttyS0', linux), isFalse);
    expect(isUartBridgePort('COM3', windows), isFalse);
  });
}
