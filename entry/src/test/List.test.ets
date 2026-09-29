import localUnitTest from './LocalUnit.test';
import otpCoreTest from './OtpCore.test';
import cryptoBridgeTest from './CryptoBridge.test';

export default function testsuite() {
  localUnitTest();
  otpCoreTest();
  cryptoBridgeTest();
}