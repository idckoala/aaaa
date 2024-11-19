from flask import Flask, render_template, request, redirect, url_for, send_from_directory
import os

app = Flask(__name__)

# โฟลเดอร์สำหรับเก็บไฟล์ที่สร้าง
CREATE_FOLDER = 'static'
app.config['CREATE_FOLDER'] = CREATE_FOLDER

# สร้างโฟลเดอร์หากยังไม่มี
if not os.path.exists(CREATE_FOLDER):
    os.makedirs(CREATE_FOLDER)

@app.route('/')
def index():
    # แสดงรายการไฟล์ทั้งหมดในโฟลเดอร์
    files = os.listdir(app.config['CREATE_FOLDER'])
    return render_template('index.html', files=files)

@app.route('/create-file', methods=['POST'])
def create_file():
    # รับข้อมูลจากฟอร์ม
    filename = request.form['filename']
    content = request.form['content']

    # กำหนดชื่อไฟล์และพาธ
    filepath = os.path.join(app.config['CREATE_FOLDER'], filename)

    try:
        # สร้างไฟล์ใหม่
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)
        return redirect(url_for('index'))
    except Exception as e:
        return f"เกิดข้อผิดพลาด: {e}"

@app.route('/file/<filename>')
def serve_file(filename):
    # ให้ดาวน์โหลดไฟล์ที่สร้างไว้
    return send_from_directory(app.config['CREATE_FOLDER'], filename, as_attachment=True)

if __name__ == '__main__':
    app.run(debug=True)
