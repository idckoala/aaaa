from flask import Flask, render_template, request, redirect, url_for, send_from_directory
import os
import requests

app = Flask(__name__)

# โฟลเดอร์สำหรับเก็บไฟล์ที่ดาวน์โหลด
DOWNLOAD_FOLDER = 'static'
app.config['DOWNLOAD_FOLDER'] = DOWNLOAD_FOLDER

# สร้างโฟลเดอร์ถ้าไม่มี
if not os.path.exists(DOWNLOAD_FOLDER):
    os.makedirs(DOWNLOAD_FOLDER)

@app.route('/')
def index():
    # แสดงไฟล์ที่ดาวน์โหลดในหน้าเว็บ
    files = os.listdir(app.config['DOWNLOAD_FOLDER'])
    return render_template('index.html', files=files)

@app.route('/download-link', methods=['POST'])
def download_link():
    url = request.form['url']  # รับลิงก์จากฟอร์ม
    if not url:
        return redirect(url_for('index'))

    try:
        # ดึงชื่อไฟล์จาก URL
        filename = url.split("/")[-1]
        filepath = os.path.join(app.config['DOWNLOAD_FOLDER'], filename)

        # ดาวน์โหลดไฟล์จากลิงก์
        response = requests.get(url, stream=True)
        response.raise_for_status()  # ตรวจสอบสถานะ HTTP

        with open(filepath, 'wb') as f:
            for chunk in response.iter_content(chunk_size=1024):
                if chunk:
                    f.write(chunk)

        return redirect(url_for('index'))  # กลับไปที่หน้าแรก
    except Exception as e:
        print(f"Error: {e}")
        return "เกิดข้อผิดพลาดในการดาวน์โหลดไฟล์"

@app.route('/file/<filename>')
def serve_file(filename):
    # ให้ผู้ใช้ดาวน์โหลดไฟล์ที่อยู่ในโฟลเดอร์
    return send_from_directory(app.config['DOWNLOAD_FOLDER'], filename, as_attachment=True)

if __name__ == '__main__':
    app.run(debug=True)
