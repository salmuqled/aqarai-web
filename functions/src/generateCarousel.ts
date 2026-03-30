import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import sharp from "sharp";

const TEMPLATE_PATH = "templates/template_main.png";
const MAX_TITLE = 120;
const MAX_AREA = 120;
const MAX_PROPERTY_TYPE = 80;
const SLIDE_SIZE = 1080;

function assertAdmin(request: {
  auth?: { uid: string; token?: Record<string, unknown> };
}): void {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "User must be authenticated");
  }
  if (request.auth.token?.admin !== true) {
    throw new HttpsError("permission-denied", "Admin only");
  }
}

function escapeXml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

function gcsPublicUrl(bucketName: string, objectPath: string): string {
  const enc = objectPath.split("/").map((p) => encodeURIComponent(p)).join("/");
  return `https://storage.googleapis.com/${bucketName}/${enc}`;
}

function demandAr(level: string): string {
  switch (level) {
    case "high":
      return "عالي";
    case "low":
      return "منخفض";
    default:
      return "متوسط";
  }
}

function clampStr(s: string, max: number): string {
  const t = s.trim();
  if (t.length <= max) return t;
  return t.slice(0, max - 1) + "…";
}

function baseSvg(inner: string): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<svg width="${SLIDE_SIZE}" height="${SLIDE_SIZE}" xmlns="http://www.w3.org/2000/svg">
  <style>
    .line1 {
      fill: #ffffff;
      font-size: 52px;
      font-weight: 700;
      font-family: "Noto Sans Arabic", "Segoe UI", "Arial Unicode MS", system-ui, sans-serif;
      text-anchor: middle;
      direction: rtl;
    }
    .line2 {
      fill: #f0f0f0;
      font-size: 42px;
      font-weight: 600;
      font-family: "Noto Sans Arabic", "Segoe UI", "Arial Unicode MS", system-ui, sans-serif;
      text-anchor: middle;
      direction: rtl;
    }
    .line3 {
      fill: #e8e8e8;
      font-size: 36px;
      font-family: "Noto Sans Arabic", "Segoe UI", "Arial Unicode MS", system-ui, sans-serif;
      text-anchor: middle;
      direction: rtl;
    }
  </style>
  ${inner}
</svg>`;
}

function slide1Svg(title: string, area: string): string {
  const t = escapeXml(title);
  const a = escapeXml(area);
  return baseSvg(`
  <text x="540" y="440" class="line1">🔥 ${t}</text>
  <text x="540" y="580" class="line2">📍 ${a}</text>
`);
}

function slide2Svg(propertyType: string): string {
  const p = escapeXml(propertyType);
  return baseSvg(`
  <text x="540" y="460" class="line1">🏠 ${p}</text>
  <text x="540" y="600" class="line2">📊 فرص متاحة الآن</text>
`);
}

function slide3Svg(dealsCount: number, demandLevel: string): string {
  const dAr = escapeXml(demandAr(demandLevel));
  const n = Math.max(0, Math.min(dealsCount, 999999));
  return baseSvg(`
  <text x="540" y="360" class="line1">📊 تحليل السوق</text>
  <text x="540" y="500" class="line2">عدد الصفقات: ${n}</text>
  <text x="540" y="620" class="line2">الطلب: ${dAr}</text>
`);
}

function slide4Svg(): string {
  return baseSvg(`
  <text x="540" y="520" class="line1">📲 حمل تطبيق AqarAi الآن</text>
`);
}

async function compositeSlide(
  templateBuffer: Buffer,
  svg: string
): Promise<Buffer> {
  return sharp(templateBuffer)
    .composite([
      {
        input: Buffer.from(svg, "utf-8"),
        top: 0,
        left: 0,
      },
    ])
    .png()
    .toBuffer();
}

/**
 * Admin-only: 4 carousel frames onto Storage template → generated_posts/carousel_{id}_{n}.png
 */
export const generateCarousel = onCall(
  {
    region: "us-central1",
    memory: "1GiB",
    timeoutSeconds: 180,
  },
  async (request) => {
    assertAdmin(request);

    const title = clampStr(
      typeof request.data?.title === "string" ? request.data.title : "",
      MAX_TITLE
    );
    const area = clampStr(
      typeof request.data?.area === "string" ? request.data.area : "",
      MAX_AREA
    );
    const propertyType = clampStr(
      typeof request.data?.propertyType === "string"
        ? request.data.propertyType
        : "",
      MAX_PROPERTY_TYPE
    );
    const rawLevel =
      typeof request.data?.demandLevel === "string"
        ? request.data.demandLevel.trim().toLowerCase()
        : "";
    const demandLevel =
      rawLevel === "high" || rawLevel === "low" || rawLevel === "medium"
        ? rawLevel
        : "medium";

    let dealsCount = 0;
    const dc = request.data?.dealsCount;
    if (typeof dc === "number" && Number.isFinite(dc)) {
      dealsCount = Math.max(0, Math.floor(dc));
    } else if (typeof dc === "string" && /^\d+$/.test(dc.trim())) {
      dealsCount = Math.max(0, parseInt(dc.trim(), 10));
    }

    if (!title) {
      throw new HttpsError("invalid-argument", "title is required");
    }
    if (!area) {
      throw new HttpsError("invalid-argument", "area is required");
    }
    if (!propertyType) {
      throw new HttpsError("invalid-argument", "propertyType is required");
    }

    const bucket = admin.storage().bucket();

    let templateBuffer: Buffer;
    try {
      [templateBuffer] = await bucket.file(TEMPLATE_PATH).download();
    } catch (e: unknown) {
      console.error("generateCarousel: template download failed", e);
      throw new HttpsError(
        "failed-precondition",
        "Upload templates/template_main.png to Firebase Storage (1080×1080 PNG)."
      );
    }

    const svgs = [
      slide1Svg(title, area),
      slide2Svg(propertyType),
      slide3Svg(dealsCount, demandLevel),
      slide4Svg(),
    ];

    let buffers: Buffer[];
    try {
      buffers = await Promise.all(
        svgs.map((svg) => compositeSlide(templateBuffer, svg))
      );
    } catch (e: unknown) {
      console.error("generateCarousel: sharp failed", e);
      throw new HttpsError("internal", "Image generation failed");
    }

    const runId = `${Date.now()}_${Math.random().toString(36).slice(2, 10)}`;
    const paths = [1, 2, 3, 4].map(
      (n) => `generated_posts/carousel_${runId}_${n}.png`
    );

    const urls: string[] = [];

    for (let i = 0; i < 4; i++) {
      const destPath = paths[i];
      const file = bucket.file(destPath);
      await file.save(buffers[i], {
        metadata: {
          contentType: "image/png",
          cacheControl: "public, max-age=31536000",
        },
        resumable: false,
      });

      try {
        await file.makePublic();
        urls.push(gcsPublicUrl(bucket.name, destPath));
      } catch (e: unknown) {
        console.warn("generateCarousel: makePublic failed, signed URL", e);
        const [signed] = await file.getSignedUrl({
          action: "read",
          expires: Date.now() + 10 * 365 * 24 * 60 * 60 * 1000,
        });
        urls.push(signed);
      }
    }

    return { success: true, images: urls };
  }
);
