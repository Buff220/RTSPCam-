# RTSPCam

Stream your iPhone camera over RTSP using hardware H264 encoding.
Connect from VLC, ffplay, OpenCV — anything that speaks RTSP.

---

## How to get the .ipa (step by step, no Mac needed)

### Step 1 — Put this code on GitHub

1. Go to **github.com** → sign in or create a free account
2. Click **New repository** (top right, green button)
3. Name it `RTSPCam`, set it to **Public**, click **Create repository**
4. On your computer, download and install **Git** from git-scm.com
5. Open a terminal / command prompt and run:

```bash
git clone https://github.com/YOUR_USERNAME/RTSPCam
# copy all these project files into the cloned folder
cd RTSPCam
git add .
git commit -m "initial"
git push origin main
```

> **Easier alternative**: On github.com, click **"uploading an existing file"** and drag
> all the files from this folder into the browser. Then commit.

---

### Step 2 — Watch GitHub build it for free

1. Go to your repo on GitHub
2. Click the **"Actions"** tab at the top
3. You should see **"Build IPA"** running (yellow circle = in progress)
4. Wait ~5 minutes for it to finish (green checkmark)
5. Click the completed run → scroll down to **Artifacts** → click **RTSPCam-IPA** to download

You now have `RTSPCam-IPA.zip` on your computer. Unzip it → you get `RTSPCam.ipa`.

---

### Step 3 — Sideload with AltStore

**On your PC:**
1. Make sure AltServer is running (system tray)
2. Connect your iPhone via USB
3. Open AltStore on your iPhone
4. Go to **My Apps** → tap **+** (top left)
5. Navigate to `RTSPCam.ipa` → tap it
6. AltStore signs and installs it

That's it. The app appears on your home screen.

---

### Step 4 — Use it

1. Make sure your iPhone and PC are on the **same WiFi network**
2. Open **RTSPCam** on your iPhone
3. Grant camera permission when asked
4. The RTSP URL appears on screen, e.g.:
   ```
   rtsp://192.168.1.42:8554/live
   ```
5. On your PC, open the stream with any of:

   ```bash
   # ffplay (part of FFmpeg)
   ffplay "rtsp://192.168.1.42:8554/live"

   # or VLC → Media → Open Network Stream → paste URL

   # or Python + OpenCV:
   import cv2
   cap = cv2.VideoCapture("rtsp://192.168.1.42:8554/live")
   while True:
       ret, frame = cap.read()
       if ret:
           cv2.imshow("iPhone Camera", frame)
           if cv2.waitKey(1) == ord('q'):
               break
   ```

---

## Technical details

| Property | Value |
|---|---|
| Protocol | RTSP 1.0 over TCP, RTP/UDP for video |
| Codec | H264 (hardware encoder, VideoToolbox) |
| Resolution | 1920×1080 |
| Target FPS | 30 |
| Target bitrate | 4 Mbps (adjustable in CameraManager.swift) |
| Port | 8554 |
| Payload type | 96 (dynamic) |
| NAL fragmentation | FU-A for large frames |

## Adjusting settings

Open `RTSPCam/CameraManager.swift` and change:

```swift
var targetBitrate: Int = 4_000_000   // bytes/sec  → 2_000_000 for less bandwidth
var targetFPS: Int32 = 30            // frames/sec → 60 for smoother (iPhone 11 supports it)
```

Then push to GitHub and let Actions rebuild.

## Troubleshooting

**"No clients connecting"**
- Make sure both devices are on the same WiFi (not mobile data)
- Check your router doesn't block device-to-device traffic
- Try disabling Windows Firewall temporarily

**Stream freezes/stutters**
- Lower bitrate to 2 Mbps
- Move closer to WiFi router

**AltStore says "App already installed"**
- Delete the old version from your phone first

**Actions build fails**
- Click the failed run → expand the failing step → read the error
- Most common issue: wrong Xcode version. Change `Xcode_15.4` to `Xcode_15.2` in the workflow file
