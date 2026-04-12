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

## الطريقة 2: عبر Cloud Function (فقط إذا عندك حساب أدمن بالفعل)

> **أول أدمن في المشروع:** استخدم **الطريقة 1** (سكربت + Service Account) أو **Firebase Console** لتعيين `admin: true` — استدعاء `setAdminClaim` **بدون** جلسة أدمن غير مدعوم (معطّل لأسباب أمنية).

1. **انشر الـ Function (إن لزم):**
   ```bash
   cd functions
   npm run build
   firebase deploy --only functions:setAdminClaim
   ```

2. **سجّل دخولاً بحساب له صلاحية أدمن** (في التطبيق أو أداة تستخدم نفس مشروع Firebase).

3. **استدعِ الدالة** (مثلاً من تطبيقك بـ Callable مع المستخدم المسجّل):
   - الـ Function اسمها: `setAdminClaim`
   - المعطيات: `{ targetUid: "YOUR_UID" }` فقط  
   (استبدل `YOUR_UID` بالـ UID من Authentication للمستخدم الجديد)

4. بعد النجاح: المستخدم الجديد يسجّل **خروج ثم دخول** ليتحمّل الـ claim الجديد.

---

## ملاحظة أمان

- `setAdminClaim` يقبل فقط من **أدمن حالي**؛ لا يوجد bootstrap مجهول الهوية عبر سر مشترك.
- لا ترفع ملف `serviceAccountKey.json` إلى Git (يجب أن يكون في `.gitignore`).
