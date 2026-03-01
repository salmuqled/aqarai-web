/**
 * تعيين صلاحية أدمن لمستخدم (مرة واحدة)
 * الاستخدام:
 *   1. حمّل مفتاح Service Account من Firebase Console:
 *      Project Settings → Service accounts → Generate new private key
 *   2. احفظ الملف في المشروع (مثلاً functions/serviceAccountKey.json)
 *   3. اعرف الـ UID من Authentication → Users (أو من لوق التطبيق)
 *   4. نفّذ من مجلد functions:
 *      node scripts/set-admin-claim.js serviceAccountKey.json YOUR_UID
 */
const admin = require("firebase-admin");
const path = require("path");

const keyPath = process.argv[2];
const uid = process.argv[3];

if (!keyPath || !uid) {
  console.error("Usage: node scripts/set-admin-claim.js <path-to-serviceAccountKey.json> <UID>");
  console.error("Example: node scripts/set-admin-claim.js serviceAccountKey.json jQivcgMYCvgf6pi5BcOd9w3PyU22");
  process.exit(1);
}

const keyFullPath = path.isAbsolute(keyPath) ? keyPath : path.join(__dirname, "..", keyPath);
let serviceAccount;
try {
  serviceAccount = require(keyFullPath);
} catch (e) {
  console.error("Failed to load key file:", keyFullPath, e.message);
  process.exit(1);
}

if (!admin.apps.length) {
  admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
}

admin
  .auth()
  .setCustomUserClaims(uid, { admin: true })
  .then(() => {
    console.log("✅ تم تعيين صلاحية الأدمن للمستخدم:", uid);
    console.log("   سجّل خروج ثم دخول من التطبيق لتحديث التوكن.");
    process.exit(0);
  })
  .catch((err) => {
    console.error("❌ خطأ:", err.message);
    process.exit(1);
  });
