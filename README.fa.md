# Universal Web2App (خلاصه‌ی فارسی)

با این پروژه تقریباً هر وب‌سایت را به برنامه‌ی نصبی **ویندوز، لینوکس، اندروید و iOS** تبدیل می‌کنید، بدون برنامه‌نویسی. سایت داخل WebView خود سیستم‌عامل اجرا می‌شود و یک پوسته‌ی کوچک و امن Rust/Tauri 2 آن را محافظت می‌کند.

## مراحل
1. مخزن را **Fork** کنید و در تب Actions فورک خود، Workflowها را **فعال** کنید.
2. `git clone` بزنید، وارد پوشه شوید و `bash scripts/setup.sh` را اجرا کنید (نیاز: `bash` و `jq`). نام برنامه، آدرس سایت، Package ID، لوگو/آیکون، رنگ‌ها، پلتفرم‌ها و قابلیت‌ها را وارد کنید. اگر خطایی رخ دهد همه‌چیز خودکار به حالت قبل برمی‌گردد.
3. `git add . && git commit -m "Configure application" && git push origin main`
4. GitHub Actions چهار Job مستقل (Windows، Linux، Android، iOS) اجرا می‌کند و فایل‌ها را در **Releases** همین مخزن می‌گذارد.

## امضا
- **اندروید** بدون Secret: فقط APK آزمایشی (`…-android-testsign.apk`) ساخته می‌شود و **AAB تولید نمی‌شود**. با ۴ Secret (`ANDROID_KEYSTORE_BASE64`، `ANDROID_KEYSTORE_PASSWORD`، `ANDROID_KEY_ALIAS`، `ANDROID_KEY_PASSWORD`) APK و AAB امضاشده می‌گیرید. برای ساخت کلید: `bash scripts/make-android-keystore.sh`.
- **iOS** بدون Secret: **IPA ساخته نمی‌شود** و فقط کامپایل‌شدن بررسی می‌شود. Secretها: `APPLE_CERTIFICATE`، `APPLE_CERTIFICATE_PASSWORD`، `APPLE_PROVISIONING_PROFILE`، `APPLE_TEAM_ID`، (اختیاری) `APPLE_SIGNING_IDENTITY`.
- ویندوز بدون امضا است (هشدار SmartScreen).

## امنیت
سایت خارجی هیچ دسترسی آزادی به Tauri/Native ندارد؛ فقط یک Bridge محدود با Allowlist، فقط برای دامنه‌های تنظیم‌شده و با تطبیق دقیق Host. گواهی SSL نامعتبر هرگز پذیرفته نمی‌شود. لینک‌های خارج از دامنه در مرورگر سیستم باز می‌شوند.

## قابلیت‌ها و محدودیت‌ها
فهرست صادقانه‌ی قابلیت‌ها (`implemented` / `platform-limited` / `planned`) در [docs/FEATURES.md](docs/FEATURES.md) و محدودیت‌ها در [docs/LIMITATIONS.md](docs/LIMITATIONS.md) است. قابلیت‌های برنامه‌ریزی‌شده (بایومتریک، NFC، Deep Link، Pull-to-Refresh، اشتراک‌گذاری و …) در این نسخه قابل فعال‌سازی نیستند.
