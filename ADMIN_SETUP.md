# تفعيل صلاحية الأدمن (حل مشكلة: الطلبات ما تظهر في لوحة الأدمن)

السبب: الطلبات غير المعتمدة (مثل طلبات المطلوب) تظهر فقط إذا كان حسابك له **صلاحية أدمن** في Firebase (Custom Claim: `admin: true`).

---

## الطريقة 1: سكربت محلي (الأبسط — بدون نشر Functions)

### 1) احصل على الـ UID
- افتح [Firebase Console](https://console.firebase.google.com) → مشروعك → **Authentication** → **Users**
- انسخ **User UID** للحساب اللي تريده أدمن (مثل: `jQivcgMYCvgf6pi5BcOd9w3PyU22`)

### 2) حمّل مفتاح Service Account
- نفس المشروع → ⚙️ **Project settings** → **Service accounts**
- اضغط **Generate new private key** → حمّل الملف JSON
- ضع الملف داخل المشروع، مثلاً: `functions/serviceAccountKey.json`  
  (أضف `functions/serviceAccountKey.json` إلى `.gitignore` ولا ترفعه على Git)

### 3) شغّل السكربت
من الطرفية (Terminal):

```bash
cd functions
node scripts/set-admin-claim.js serviceAccountKey.json YOUR_UID
```

استبدل `YOUR_UID` بالـ UID اللي نسخته (مثال: `jQivcgMYCvgf6pi5BcOd9w3PyU22`).

### 4) حدّث التوكن في التطبيق
- **سجّل خروج** من التطبيق ثم **سجّل دخول** مرة ثانية
- بعدها ادخل **طلبات الأدمن** → تبويب **مطلوب** — يفترض تظهر الطلبات وزر **اعتماد**

---

## الطريقة 2: عبر Cloud Function (إذا فضّلت عدم استخدام المفتاح محلياً)

1. **انشر الـ Function:**
   ```bash
   cd functions
   npm run build
   firebase deploy --only functions
   ```

2. **استدعِ الدالة مرة واحدة** بأي طريقة تناسبك، مثلاً من متصفح (Console) أو من تطبيقك:
   - الـ Function اسمها: `setAdminClaim`
   - المعطيات: `{ targetUid: "YOUR_UID", secret: "aqarai_admin_setup_2025" }`  
   (استبدل `YOUR_UID` بالـ UID من Authentication)

3. بعد النجاح: **سجّل خروج ثم دخول** من التطبيق.

---

## ملاحظة أمان

- في الطريقة 2، كلمة السر مضمّنة في الكود (`aqarai_admin_setup_2025`). بعد ما تفعّل الأدمن يمكنك تغييرها أو تعطيل استدعاء الدالة.
- لا ترفع ملف `serviceAccountKey.json` إلى Git (يجب أن يكون في `.gitignore`).
