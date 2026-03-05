# setup-object-cache.sh

Script สำหรับตั้งค่า **LiteSpeed Object Cache (Redis)** อัตโนมัติ ครอบคลุมทุก WordPress บนเซิร์ฟเวอร์ cPanel

---

## ทำอะไร?

Script นี้จะวิ่งเข้าไปในทุก cPanel Account บนเซิร์ฟเวอร์ ค้นหาทุก WordPress ที่ติดตั้งอยู่ แล้วตรวจสอบและตั้งค่า LiteSpeed Cache ให้ใช้ Redis Object Cache ผ่าน Unix Socket โดยอัตโนมัติ

---

## ความต้องการก่อนรัน

| สิ่งที่ต้องมี | รายละเอียด |
|---|---|
| **WP-CLI** | ต้องติดตั้งและเรียกใช้ได้จาก command line |
| **Redis** | ต้องรันอยู่และมี socket ที่ `/var/run/redis/redis.sock` |
| **LiteSpeed Cache Plugin** | ต้องติดตั้งและ activate อยู่ในแต่ละ WordPress |
| **cPanel Server** | รองรับ `/home` และ `/home2` |
| **root access** | ต้องรันด้วยสิทธิ์ root |

---

## วิธีใช้งาน

```bash
bash setup-object-cache.sh
```

---

## การทำงานของ Script

### ขั้นตอนที่ 1 — Pre-flight Check
ก่อนเริ่มทำงาน script จะตรวจสอบ:
- WP-CLI ติดตั้งอยู่หรือไม่
- Redis Socket มีอยู่ที่ `/var/run/redis/redis.sock` หรือไม่
- Redis ตอบสนอง (`PING → PONG`) หรือไม่

หากขาดสิ่งใดสิ่งหนึ่ง script จะหยุดทันทีพร้อมแจ้งสาเหตุ

---

### ขั้นตอนที่ 2 — PRE-SCAN cPanel Accounts
สแกนหา cPanel accounts ทั้งหมดบนเซิร์ฟเวอร์ โดยอ่านจาก 3 แหล่งตามลำดับ:

1. `/var/cpanel/users/` — แม่นที่สุด (มีใน cPanel ปกติ)
2. `/etc/trueuserdomains` — fallback
3. สแกน directory ตรงๆ — fallback สุดท้าย

แสดงสรุปว่ามีกี่ account และอยู่ใน `/home` หรือ `/home2`

---

### ขั้นตอนที่ 3 — สแกนหา WordPress
ค้นหา WordPress ทุกเว็บในทุก account โดย:
- ใช้ `find` วิ่งหา `wp-config.php` ลึกสูงสุด 6 ชั้น
- **Validate** ว่าเป็น WordPress จริงโดยเช็ค `wp-includes/version.php`
- **Dedup ด้วย inode** ป้องกันนับซ้ำเมื่อมี symlink
- ข้าม path ที่เป็น backup, cache, node_modules, wp-content

รองรับทุก directory structure เช่น:
```
/home/user/public_html/domain.com/     ← addon domain แบบ classic
/home/user/domain.com/                 ← document root ตรง
/home/user/domain.com/public_html/     ← มี public_html ซ้อน
```

---

### ขั้นตอนที่ 4 — ตรวจสอบและแก้ไข (Single-Pass)
ทำงานแบบ **parallel** ตามจำนวน CPU cores และ RAM ที่มี

แต่ละเว็บจะถูกตรวจสอบ 6 ค่า และแก้ไขเฉพาะค่าที่ผิดเท่านั้น:

| ค่าที่ตรวจสอบ | ค่าที่ถูกต้อง |
|---|---|
| Object Cache | ON (1) |
| Method | Redis (1) |
| Host | `/var/run/redis/redis.sock` |
| Port | `0` (ใช้ socket ไม่ใช้ port) |
| Username | ว่างเปล่า |
| Password | ว่างเปล่า |

---

## ความหมายของผลลัพธ์

### `✔️  Object Cache Already Set`
```
✔️  Object Cache Already Set : [12/186] [home/d13752] winners789.co
```
**ความหมาย:** เว็บนี้ตั้งค่า Object Cache ไว้ถูกต้องครบทุก field อยู่แล้ว script ไม่ได้แตะหรือเปลี่ยนแปลงค่าใดๆ ทั้งสิ้น

---

### `🔧 Object Cache Fixed`
```
🔧 Object Cache Fixed : [13/186] [home/d13752] lkf888.co  ⚙️ Host: '127.0.0.1' ► /var/run/redis/redis.sock  | ⚙️ Port: '6379' ► 0
```
**ความหมาย:** เว็บนี้มีบางค่าที่ตั้งไว้ไม่ถูกต้อง script ตรวจพบและแก้ไขเรียบร้อยแล้ว โดยแสดงให้เห็นว่า:
- แก้ไขค่าอะไรบ้าง
- ค่าเดิมเป็นอะไร (`'127.0.0.1'`)
- ค่าใหม่ที่แก้เป็นอะไร (`/var/run/redis/redis.sock`)

**สัญลักษณ์ ⚙️** หมายถึงรายการที่ถูกอัปเดต

---

### `❌ FAILED`
```
❌ FAILED : [14/186] [home/d13752] badsite.co
```
**ความหมาย:** เว็บนี้มีค่าที่ต้องแก้ไข แต่ script แก้ไขไม่สำเร็จ อาจเกิดจาก:
- Database ของ WordPress เว็บนั้นเชื่อมต่อไม่ได้
- WP-CLI timeout (เกิน 30 วินาที)
- สิทธิ์การเข้าถึงไม่เพียงพอ
- WordPress มีปัญหาภายใน

**วิธีแก้:** ตรวจสอบเว็บนั้นด้วยตนเองผ่าน cPanel หรือ WP-CLI

---

### `⏭️  ข้าม (Skipped)`
เว็บที่ถูกข้ามโดยไม่มีการแสดงผลใดๆ เกิดจาก:
- ไม่ได้ติดตั้ง LiteSpeed Cache Plugin
- ติดตั้งแต่ Plugin ถูก deactivate อยู่

---

## ตัวเลข Progress `[N/TOTAL]`

```
✔️  Object Cache Already Set : [12/186] [home/d13752] winners789.co
```

- `12` = เว็บที่ process เสร็จแล้ว (นับสะสม)
- `186` = จำนวน WordPress ทั้งหมดที่พบบนเซิร์ฟเวอร์

> **หมายเหตุ:** เนื่องจาก script รันแบบ parallel ตัวเลขอาจไม่เรียงตามลำดับ เช่น 3, 1, 5, 2 — นี่เป็นเรื่องปกติ ไม่ใช่ข้อผิดพลาด

---

## สรุปผลรวม (Summary)

```
======================================
 สรุปผลรวม
 👥 cPanel Accounts    : 4 accounts
    /home  : 0 | /home2 : 1 | ทั้งคู่ : 3
--------------------------------------
 รวม WordPress          : 186 เว็บ (นับจากผลจริง)
 ✔️  Object Cache Already Set : 53 เว็บ (ตั้งค่าไว้ถูกต้องอยู่แล้วไม่ได้ปรับเปลี่ยน)
 🔧 Object Cache Fixed        : 133 เว็บ (อัปเดตเรียบร้อย)
 ❌ แก้ไขไม่สำเร็จ            : 0 เว็บ
 ⏭  ข้ามทั้งหมด               : 0 เว็บ
 เวลาที่ใช้                   : 1 นาที 23 วินาที
======================================
```

| ฟิลด์ | ความหมาย |
|---|---|
| **Object Cache Already Set** | จำนวนเว็บที่ตั้งค่าถูกต้องอยู่แล้ว ไม่ได้แก้ไขอะไร |
| **Object Cache Fixed** | จำนวนเว็บที่ตรวจพบค่าผิดและแก้ไขสำเร็จแล้ว |
| **แก้ไขไม่สำเร็จ** | จำนวนเว็บที่แก้ไขไม่ได้ ต้องตรวจสอบเพิ่มเติม |
| **ข้ามทั้งหมด** | จำนวนเว็บที่ไม่มี LiteSpeed Cache หรือ plugin ถูก deactivate |
| **เวลาที่ใช้** | เวลารวมตั้งแต่เริ่มจนจบ |

---

## Log File

ทุก output จะถูกบันทึกลงที่:
```
/var/log/lscwp-setup.log
```

สามารถ tail log แบบ real-time ขณะรันได้:
```bash
tail -f /var/log/lscwp-setup.log
```

---

## การคำนวณ Parallel Jobs อัตโนมัติ

Script คำนวณจำนวน parallel jobs จาก CPU และ RAM:

```
MAX_JOBS = min(CPU_CORES, TOTAL_RAM / 200MB)
ขั้นต่ำ  = 1 job
สูงสุด   = 20 jobs
```

ตัวอย่าง: เซิร์ฟเวอร์ 12 cores, RAM 47GB → MAX_JOBS = 12

---

## ค่าที่ Script ตั้งให้

```
Object Cache  = ON
Method        = Redis
Host          = /var/run/redis/redis.sock
Port          = 0
Username      = (ว่างเปล่า)
Password      = (ว่างเปล่า)
```

การใช้ Unix Socket (`redis.sock`) แทน TCP (`127.0.0.1:6379`) ให้ประสิทธิภาพสูงกว่าเพราะไม่ผ่าน network stack

---

## Timeout

แต่ละ WP-CLI call มี timeout 30 วินาที หากเว็บใดใช้เวลาเกินกว่านั้น จะถูก skip และนับเป็น FAILED
