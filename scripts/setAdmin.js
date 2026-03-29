/**
 * تعيين Custom Claim: admin=true لمستخدم واحد.
 *
 * 1) انسخ من Firebase Console → Project settings → Service accounts
 *    ملف المفتاح واحفظه هنا باسم: serviceAccountKey.json
 * 2) من Terminal:
 *    cd scripts
 *    npm install
 *    export FIREBASE_UID="ضع_الـ_UID_الكامل_هنا"
 *    node setAdmin.js
 *
 * 3) في التطبيق: تسجيل خروج ثم دخول.
 */

const admin = require("firebase-admin");
const path = require("path");
const fs = require("fs");

/**
 * يدعم: متغير بيئة، أو serviceAccountKey.json، أو أي ملف *firebase-adminsdk*.json بنفس المجلد.
 */
function resolveServiceAccountPath() {
  const fromEnv = process.env.SERVICE_ACCOUNT_JSON;
  if (fromEnv && fs.existsSync(fromEnv)) return path.resolve(fromEnv);

  const exact = path.join(__dirname, "serviceAccountKey.json");
  if (fs.existsSync(exact)) return exact;

  let entries = [];
  try {
    entries = fs.readdirSync(__dirname);
  } catch (_) {
    entries = [];
  }
  const adminSdk = entries.filter(
    (n) =>
      n.endsWith(".json") &&
      n.includes("firebase-adminsdk") &&
      !n.includes("package")
  );
  if (adminSdk.length === 1) {
    return path.join(__dirname, adminSdk[0]);
  }
  if (adminSdk.length > 1) {
    console.error("❌ أكثر من ملف firebase-adminsdk — سمّ واحد منهم serviceAccountKey.json أو استخدم SERVICE_ACCOUNT_JSON");
    adminSdk.forEach((n) => console.error("   -", n));
    process.exit(1);
  }

  console.error("❌ ما لقيت مفتاح الخدمة.");
  console.error("   مجلد السكربت (__dirname):", __dirname);
  console.error("   ملفات .json هنا (غير node_modules):");
  for (const n of entries) {
    if (n.endsWith(".json")) console.error("   -", JSON.stringify(n));
  }
  console.error(
    "\n   الحل: حط الملف هنا باسم serviceAccountKey.json\n" +
      "   أو عيّن مسار كامل:\n" +
      '   export SERVICE_ACCOUNT_JSON="/full/path/to/key.json"'
  );
  process.exit(1);
}

const keyPath = resolveServiceAccountPath();
console.log("   Using key file:", keyPath);

const serviceAccount = require(keyPath);

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
});

const uid = process.env.FIREBASE_UID || "";

if (!uid.trim()) {
  console.error(
    "❌ حط الـ UID في المتغير FIREBASE_UID، مثال:\n" +
      '   export FIREBASE_UID="xxxxxxxxxxxxxxxx" && node setAdmin.js'
  );
  process.exit(1);
}

admin
  .auth()
  .setCustomUserClaims(uid.trim(), { admin: true })
  .then(() => {
    console.log("✅ تم: admin=true للمستخدم", uid.trim());
    return admin.auth().getUser(uid.trim());
  })
  .then((u) => {
    console.log("   customClaims =", u.customClaims);
    process.exit(0);
  })
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
