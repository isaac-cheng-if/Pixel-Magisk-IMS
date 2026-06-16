set -e
export ANDROID_HOME=/sdk
if [ ! -f /sdk/platforms/android-34/android.jar ]; then
  echo "=== installing SDK (first time) ==="
  apt-get update -qq && apt-get install -y -qq unzip curl >/dev/null 2>&1
  mkdir -p /sdk/cmdline-tools
  cd /tmp
  curl -fsSLO https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
  unzip -q commandlinetools-linux-11076708_latest.zip -d /sdk/cmdline-tools
  mv /sdk/cmdline-tools/cmdline-tools /sdk/cmdline-tools/latest
  yes | /sdk/cmdline-tools/latest/bin/sdkmanager --licenses >/dev/null 2>&1 || true
  /sdk/cmdline-tools/latest/bin/sdkmanager "platforms;android-34" "build-tools;34.0.0" >/dev/null
else
  echo "=== SDK cached, skipping install ==="
fi
cd /work
rm -rf classes classes.dex
mkdir -p classes
javac -cp /sdk/platforms/android-34/android.jar -d classes CarrierConfigInjector.java
/sdk/build-tools/34.0.0/d8 --min-api 26 --lib /sdk/platforms/android-34/android.jar --output /work classes/com/ifchy/ctims/*.class
echo "=== output ==="; ls -la /work/classes.dex; echo BUILD_OK
