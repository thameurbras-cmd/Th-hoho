# -*- coding: utf-8 -*-
"""
ID-to-PDF Bridge — برنامج الحاسوب
يستقبل بيانات البطاقة من الهاتف عبر Wi-Fi، ويملأ استمارة PDF، ويحفظها.

التثبيت (مرة واحدة):
    pip install flask pypdf reportlab arabic-reshaper python-bidi

التشغيل:
    python id_to_pdf_server.py          ← يفتح النافذة ويعرض عنوان الحاسوب
    python id_to_pdf_server.py --list   ← يعرض أسماء حقول الاستمارة (ويحفظها في fields.txt)

الملفات:
    form_template.pdf   ← الاستمارة الفارغة (بجانب هذا السكربت)
    output_pdfs/        ← الاستمارات المملوءة
"""

import io
import logging
import os
import queue
import re
import socket
import sys
import threading
from datetime import datetime
from pathlib import Path

import arabic_reshaper
from bidi.algorithm import get_display
from flask import Flask, jsonify, request
from pypdf import PdfReader, PdfWriter
from pypdf.generic import ArrayObject, NameObject
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas

# ───────────────────────────── الإعدادات ─────────────────────────────

BASE_DIR = Path(__file__).resolve().parent
TEMPLATE_PDF = BASE_DIR / "form_template.pdf"
OUTPUT_DIR = BASE_DIR / "output_pdfs"
PORT = 8000

# خط يدعم العربية (يُجرَّب بالترتيب)
FONT_CANDIDATES = [
    r"C:\Windows\Fonts\tahoma.ttf",
    r"C:\Windows\Fonts\arial.ttf",
]
FONT_SIZE = 12  # يصغر تلقائياً إذا لم يتسع النص في الحقل

# ربط يدوي (اختياري): ضع اسم الحقل كما يظهر في --list.
# إذا تُرك None يحاول البرنامج التعرف على الحقل من اسمه تلقائياً.
FIELD_MAP = {
    "first_name": None,   # الاسم
    "last_name": None,    # اللقب
    "birth": None,        # تاريخ ومكان الازدياد (حقل واحد)
    "national_id": None,  # رقم التعريف الوطني
    "issue_date": None,   # تاريخ الصدور
    "issue_place": None,  # مكان الإصدار
}

# كلمات للتعرف التلقائي على الحقول (الترتيب مهم: الأخص أولاً)
AUTO_KEYWORDS = {
    "first_name": ["الاسم", "prenom", "given"],
    "issue_place": ["مكان الاصدار", "مكان الصدور", "lieu de deliv", "place of issue"],
    "issue_date": ["تاريخ الاصدار", "تاريخ الصدور", "date de deliv", "date of issue"],
    "birth": ["الازدياد", "الميلاد", "naissance", "birth"],
    "national_id": ["التعريف", "الوطني", "nin"],
    "last_name": ["اللقب", "لقب", "nom", "surname"],
}

# ───────────────────────────── أدوات مساعدة ─────────────────────────────

ARABIC_CHARS = re.compile(r"[\u0600-\u06FF]")


def norm(text: str) -> str:
    """توحيد النص للمقارنة (همزات الألف، التاء المربوطة، الحروف اللاتينية المشكّلة)."""
    text = text.lower()
    for a in "أإآ":
        text = text.replace(a, "ا")
    text = text.replace("ى", "ي").replace("ة", "ه")
    text = text.replace("é", "e").replace("è", "e").replace("ê", "e")
    return re.sub(r"[\s_\-.:/]+", " ", text).strip()


def shape(text: str) -> str:
    """تشكيل الحروف العربية وترتيبها من اليمين لليسار قبل الرسم على الـPDF."""
    if ARABIC_CHARS.search(text):
        return get_display(arabic_reshaper.reshape(text))
    return text


def register_font() -> str:
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            pdfmetrics.registerFont(TTFont("FormFont", path))
            return "FormFont"
    raise RuntimeError("لم يتم العثور على خط يدعم العربية. عدّل FONT_CANDIDATES.")


def qualified_name(annot) -> str:
    """الاسم الكامل للحقل (يشمل الحقول الأب) كما يعيده pypdf في get_fields()."""
    parts, node = [], annot
    while node is not None:
        title = node.get("/T")
        if title is not None:
            parts.append(str(title))
        parent = node.get("/Parent")
        node = parent.get_object() if parent is not None else None
    return ".".join(reversed(parts))


def resolve_fields(field_names):
    """يعيد قاموساً: مفتاح البيانات ← اسم حقل الـPDF."""
    chosen, taken = {}, set()
    for key, manual in FIELD_MAP.items():
        if manual:
            chosen[key] = manual
            taken.add(manual)
    for key, keywords in AUTO_KEYWORDS.items():
        if key in chosen:
            continue
        for name in field_names:
            if name in taken:
                continue
            if any(norm(k) in norm(name) for k in keywords):
                chosen[key] = name
                taken.add(name)
                break
    return chosen


def build_values(data: dict) -> dict:
    """يحوّل JSON القادم من الهاتف إلى القيم التي ستُكتب في الاستمارة."""
    get = lambda k: str(data.get(k, "")).strip()
    birth = get("birth_date")
    if get("birth_place"):
        birth = f"{birth} بـ {get('birth_place')}" if birth else get("birth_place")
    return {
        "first_name": get("first_name"),
        "last_name": get("last_name"),
        "birth": birth,
        "national_id": get("national_id"),
        "issue_date": get("issue_date"),
        "issue_place": get("issue_place"),
    }


def safe_filename(values: dict) -> str:
    parts = [values["last_name"], values["first_name"], values["national_id"]]
    name = "_".join(p for p in parts if p) or datetime.now().strftime("form_%Y%m%d_%H%M%S")
    name = re.sub(r'[\\/:*?"<>|\s]+', "_", name).strip("_")
    path = OUTPUT_DIR / f"{name}.pdf"
    if path.exists():  # لا نستبدل ملفاً سابقاً
        name += datetime.now().strftime("_%H%M%S")
    return name


# ───────────────────────────── تعبئة الـ PDF ─────────────────────────────
# نرسم النص فوق مستطيل كل حقل ثم نحذف الحقل (flatten). هذه الطريقة تضمن
# ظهور العربية متصلة الحروف وسليمة، بخلاف التعبئة المباشرة للحقول.

def fill_pdf(values: dict, out_path: Path) -> list:
    reader = PdfReader(str(TEMPLATE_PDF))
    names = list((reader.get_fields() or {}).keys())
    targets = resolve_fields(names)
    by_field = {targets[k]: v for k, v in values.items() if k in targets and v}
    missing = [k for k in values if k not in targets]

    writer = PdfWriter(clone_from=reader)
    font = register_font()

    for page in writer.pages:
        annots = page.get("/Annots")
        if not annots:
            continue
        width, height = float(page.mediabox.width), float(page.mediabox.height)
        buf = io.BytesIO()
        pen = canvas.Canvas(buf, pagesize=(width, height))
        keep, drew = ArrayObject(), False

        for ref in annots:
            annot = ref.get_object()
            if annot.get("/Subtype") == "/Widget":
                name = qualified_name(annot)
                if name in by_field:
                    x0, y0, x1, y1 = [float(v) for v in annot["/Rect"]]
                    left, right = min(x0, x1), max(x0, x1)
                    bottom, top = min(y0, y1), max(y0, y1)
                    text = shape(by_field[name])
                    size = FONT_SIZE
                    while pdfmetrics.stringWidth(text, font, size) > (right - left - 6) and size > 7:
                        size -= 0.5
                    pen.setFont(font, size)
                    pen.drawRightString(right - 3, bottom + (top - bottom - size) / 2 + 2, text)
                    drew = True
                    continue
            keep.append(ref)

        if drew:
            pen.save()
            buf.seek(0)
            page.merge_page(PdfReader(buf).pages[0])
            page[NameObject("/Annots")] = keep

    OUTPUT_DIR.mkdir(exist_ok=True)
    with open(out_path, "wb") as f:
        writer.write(f)
    return missing


# ───────────────────────────── الخادم ─────────────────────────────

app = Flask(__name__)
events: "queue.Queue[tuple]" = queue.Queue()  # رسائل تظهر في النافذة


@app.get("/ping")
def ping():
    return jsonify(ok=True, message="الحاسوب جاهز")


@app.post("/fill")
def fill():
    try:
        data = request.get_json(force=True)
        values = build_values(data)
        if not (values["first_name"] or values["last_name"]):
            return jsonify(ok=False, message="لا يوجد اسم أو لقب في البيانات المرسلة"), 400

        out = OUTPUT_DIR / f"{safe_filename(values)}.pdf"
        missing = fill_pdf(values, out)
        message = f"تم حفظ الملف: {out.name}"
        if missing:
            message += "\nلم يُعثر على حقل لـ: " + "، ".join(missing)
        events.put(("ok", message))
        return jsonify(ok=True, message=message)

    except FileNotFoundError:
        message = "ملف form_template.pdf غير موجود بجانب البرنامج"
    except Exception as exc:  # noqa: BLE001
        message = f"حدث خطأ: {exc}"
    events.put(("error", message))
    return jsonify(ok=False, message=message), 500


# ───────────────────────────── النافذة ─────────────────────────────

def local_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def run_gui() -> None:
    import tkinter as tk

    root = tk.Tk()
    root.title("جسر البطاقة والاستمارة")
    root.geometry("680x380")

    tk.Label(root, text="اكتب هذا العنوان في تطبيق الهاتف:",
             font=("Tahoma", 18)).pack(pady=(26, 4))
    tk.Label(root, text=f"{local_ip()}:{PORT}",
             font=("Consolas", 34, "bold"), fg="#0a7a5c").pack()
    status = tk.Label(root, text="في انتظار البطاقة…", font=("Tahoma", 20),
                      wraplength=620, justify="center")
    status.pack(pady=30)

    def poll():
        try:
            while True:
                kind, message = events.get_nowait()
                status.config(text=message, fg="#0a7a5c" if kind == "ok" else "#c0392b")
        except queue.Empty:
            pass
        root.after(300, poll)

    poll()
    root.mainloop()


def list_fields() -> None:
    reader = PdfReader(str(TEMPLATE_PDF))
    names = list((reader.get_fields() or {}).keys())
    (BASE_DIR / "fields.txt").write_text("\n".join(names), encoding="utf-8")
    print(f"عدد الحقول: {len(names)} — حُفظت في fields.txt")
    for key, field in resolve_fields(names).items():
        print(f"{key}  ←  {field}")


if __name__ == "__main__":
    if "--list" in sys.argv:
        list_fields()
    else:
        logging.getLogger("werkzeug").setLevel(logging.ERROR)
        threading.Thread(
            target=lambda: app.run(host="0.0.0.0", port=PORT, threaded=True),
            daemon=True,
        ).start()
        run_gui()
