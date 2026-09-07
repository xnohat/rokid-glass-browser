# Rokid Glasses RV101 — nghiên cứu input/control

**Ngày khảo sát:** 2026-09-06 (Asia/Ho_Chi_Minh)  
**Thiết bị kiểm tra:** serial `1904092623382901`, model Android `RG-glasses`, Android 12.  
**Phạm vi an toàn:** chỉ đọc web/ADB; không inject input, không cài app, không đổi setting.

## Kết luận ngắn

Ngoài swipe/tap/double-tap, các đường điều khiển có cơ sở thực tế gồm: **nút vật lý/Android key events**, **giọng nói (ASR/AI assistant)**, và **Bluetooth với phone/peripheral**. **Head gesture** và **hand/air gesture** là khả năng được Rokid quảng bá ở một số dòng/đời, nhưng chưa có bằng chứng đủ trực tiếp để khẳng định RV101 firmware hiện tại expose chúng cho app bên thứ ba. Tài liệu SDK chính thức tìm được là cho **Rokid Glass3**, không nên áp thẳng cho RV101.

## Ma trận mức độ chắc chắn

| Cơ chế | Mức cho RV101 | Bằng chứng / giới hạn | Hướng tích hợp thực tế |
|---|---|---|---|
| Phím vật lý / Android key event | **Đã xác minh có input device** | ADB `/proc/bus/input/devices` có `ROKID,PSOC-TP-R`, handlers `event1`, key bitmap; trước đó `getevent -lp` liệt kê ENTER, UP, LEFT, RIGHT, DOWN, PROG1/2/3, BACK, F13/F14, DASHBOARD. Bitmap/capability **không chứng minh mapping gesture**. | App có thể đọc key events nếu quyền/foreground policy cho phép; cần test observer read-only hoặc app-side logging, không giả định mọi code được dispatch tới app.
| Touch gestures | **Đã xác minh ở mức sản phẩm** | Bài hướng dẫn Rokid chính thức mô tả tap/swipe và Home/Back/volume hardware controls; không công bố đầy đủ long-press/three-finger cho RV101. | Dùng touch hiện có; các gesture nâng cao chỉ coi là chưa xác minh.
| Voice / ASR / AI | **Khả năng cao, chưa chứng minh API RV101** | Trang SDK chính thức của Rokid mô tả module Voice and AI (ASR/TTS/AI chat), nhưng trang đó nói rõ SDK chạy trên Rokid Glass3. | Có thể dùng assistant/voice commands ở consumer layer; SDK bên thứ ba trên RV101 cần xác nhận riêng bằng package/API hoặc tài liệu vendor.
| Bluetooth phone link | **Đã xác minh có pairing; HID chưa xác minh trên RV101** | Hướng dẫn Rokid mô tả pairing companion app qua Bluetooth/Wi‑Fi. SDK Glass3 có module “Bluetooth and ring”. Một thảo luận Reddit nói keyboard/mouse HID hoạt động, nhưng là nguồn cộng đồng và chưa model-specific. | Phone companion/trackpad là đường đáng tin cậy; Bluetooth HID keyboard/mouse chỉ nên coi là plausible, cần kiểm tra profile thực tế.
| Head motion / head gesture | **Chưa xác minh RV101** | Rokid quảng bá “head gestures” cho một số sản phẩm khác; Kickstarter FAQ của dòng Rokid Glasses mới nêu nod answer / shake decline. Không phải bằng chứng RV101 có event API. | Có thể tự xử lý sensor nếu sensor stream exposed; trước hết kiểm tra `dumpsys sensorservice`/sensor list và quyền. Không suy luận từ việc Android có IMU.
| Hand/air gesture | **Chưa xác minh / có thể model-dependent** | Open Platform mô tả YodaOS-Master có gesture recognition, nhưng không nói RV101 và không phải proof API. | Không nên thiết kế phụ thuộc nếu chưa có camera/SDK/event stream.
| Bluetooth ring / external controller | **Plausible, model/SDK-dependent** | Glass3 SDK liệt kê “Bluetooth and ring”; đây là tài liệu Glass3. | Chỉ triển khai sau khi xác nhận tương thích RV101; có thể dùng external BLE HID nếu OS nhận.
| Accessibility/global automation | **Chưa xác minh; bị giới hạn quyền** | Android package list có nhiều dịch vụ Rokid hệ thống; không có bằng chứng app user được phép inject/global actions. | Không dùng làm giả định; cần privileged permission/root hoặc API công khai.

## Bằng chứng ADB read-only trên RV101

Lệnh đã chạy với serial nêu trên:

```text
adb -s 1904092623382901 shell getprop ro.product.model
RG-glasses
adb -s 1904092623382901 shell getprop ro.build.version.release
12
```

`/proc/bus/input/devices` trả về:

```text
N: Name="ROKID,PSOC-TP-R"
S: Sysfs=.../input/input1
H: Handlers=event1 cpufreq
B: EV=3
B: KEY=1400 180000040300000 168000000000 10000000
```

Điều này xác nhận touch/power input device và một bitmap key capability ở kernel input layer. Nó **không** xác nhận từng mã `ENTER/UP/...` được map vào thao tác cụ thể, cũng không xác nhận app thường có thể bắt mọi event. Không chạy `getevent` lâu dài và không gửi `input keyevent`.

Packages Rokid hệ thống/product quan sát được:

```text
com.rokid.os.sprite.live
com.rokid.sysconfig
com.rokid.os.sprite.record
com.rokid.glass.ota
com.rokid.cxrservice
com.rokid.os.master.screenstream
com.rokid.os.sprite.assistserver
com.rokid.os.sprite.launcher
```

Tên package cho thấy có live/record/assist/launcher/CXR service, nhưng package presence không chứng minh public intent/API. Đặc biệt `sprite`/`master` phản ánh nhiều thế hệ YodaOS; không dùng tên package để kết luận RV101 thuộc SDK Glass3.

## Nguồn chính và cách diễn giải

1. **Rokid Open Platform** — https://open.rokid.com/ (truy cập 2026-09-06). Trang SDK chính thức; kết quả tìm kiếm của Rokid mô tả YodaOS-Master có SLAM, gesture recognition, spatial audio. Đây là nền tảng chung, không phải RV101-specific.
2. **Rokid Sprite Enterprise — Glasses SDK** — https://x-docs.rokid.com/docs/en/terminal-sdk/glasses/ (truy cập 2026-09-06). Nêu rõ “Glasses SDK is for applications running on Rokid Glass3”; module gồm device/system, voice & AI, Bluetooth and ring, media, messaging. Đây là bằng chứng tốt cho capability của Glass3, chỉ là bằng chứng tham khảo cho RV101.
3. **Rokid Global — Quick Setup & Controls Overview** — https://global.rokid.com/blogs/glasses/how-to-use-rokid-glasses-quick-setup-controls-overview (truy cập 2026-09-06). Mô tả tap/swipe, Home/Back, volume hardware buttons và pairing Bluetooth/Wi‑Fi. Bài không ghi model RV101, nên chỉ dùng cho control family của Rokid.
4. **Rokid Global — AI Glasses Style product page** — https://global.rokid.com/products/rokid-ai-glasses-style (truy cập 2026-09-06). Nêu “Voice, touch and head gestures” cho AI Glasses Style; **không áp dụng mặc định cho RV101**.
5. **Rokid Kickstarter FAQ** — https://www.kickstarter.com/projects/rokid/new-rokid-glassesworlds-lighest-full-function-ai-glasses/faqs (truy cập 2026-09-06). Search snippet nêu voice/touch và nod-to-answer/shake-to-decline; nhiều khả năng dòng Rokid Glasses mới, không phải bằng chứng firmware RV101.
6. **Community reverse-engineering docs** — https://github.com/buildwithfenna/rokid-docs và https://github.com/Anezium/awesome-rokid (truy cập 2026-09-06). Có tham chiếu head-gesture cursor, motion sensors, browser/trackpad và YodaOS internals; dùng để lập giả thuyết điều tra, không coi là vendor guarantee.
7. **RV101 Android 12 secondary report** — https://medium.com/@20x05zero/rooting-the-rokid-ar-glasses-a-22-session-deep-dive-into-android-security-research-164c6bb11321 (truy cập 2026-09-06). Search result xác nhận model RV101 chạy Android 12 trên Qualcomm; trong khảo sát này, ADB trực tiếp là bằng chứng mạnh hơn.

## Khuyến nghị cho browser/companion app

- Ưu tiên **companion phone trackpad/keyboard** hoặc Bluetooth keyboard/mouse chuẩn Android nếu pairing thực tế thành công; đây là đường ít phụ thuộc vào private Rokid API.
- Ở glasses-side, xử lý **KeyEvent** cho các nút được dispatch tới app, nhưng xây fallback vì launcher/system có thể bắt trước; đừng hard-code từ `getevent -lp`.
- Dùng voice ở tầng assistant nếu người dùng cần hands-free; nếu cần app custom, xác nhận public SDK tương thích RV101 trước.
- Xem head motion là enhancement tùy chọn: chỉ bật sau khi xác nhận sensor list + event ownership trên đúng firmware; không gọi đó là “gesture control” chỉ vì thấy IMU hoặc key capability.
- Không phụ thuộc hand gesture, ring SDK, Glass3 APIs, hay hidden intents cho bản RV101 nếu chưa kiểm tra bằng một PoC có version/firmware cụ thể.

**Tóm lại:** các lựa chọn “ngoài swipe/tap/doubletap” đáng tin nhất hiện tại là hardware key events, voice ở consumer layer, và phone-side/Bluetooth input. Head gesture/HID/ring/gesture SDK tồn tại trong hệ sinh thái Rokid nhưng cần gắn nhãn model-dependent và chưa verified cho RV101.
