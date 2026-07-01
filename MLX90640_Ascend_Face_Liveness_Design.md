# 昇腾人脸识别与 MLX90640 红外活体检测系统设计文档

## 1. 文档说明

本文档用于说明如何将现有的昇腾人脸识别考勤系统与基于 STM32F103 + MLX90640 的红外温度阵列采集系统结合，实现“人脸识别 + 红外活体检测”的考勤方案。

当前已有基础：

- STM32F103 示例工程已经能够读取 MLX90640 红外传感器数据。
- STM32F103 已经能够通过串口向电脑或上位机输出 `32×24` 温度阵列。
- 昇腾人脸识别系统已经能够完成摄像头采集、人脸检测、人脸识别和考勤记录。
- 当前目标是在考勤写入之前增加活体检测，防止使用照片、屏幕图片等方式误打卡。

开发周期：**6 天**。

整体实现路线分为两个阶段：

1. **简单方案**：直接从 `32×24=768` 个温度点中判断是否存在足够数量的人体温度点。
2. **进阶方案**：根据摄像头识别到的人脸范围，映射到 MLX90640 温度矩阵中的对应区域，只判断人脸附近的温度是否满足活体条件。

---

## 2. 项目目标

### 2.1 功能目标

系统最终需要实现：

- 摄像头检测人脸。
- 昇腾模型完成人脸识别。
- 串口实时接收 MLX90640 的 `32×24` 温度矩阵。
- 根据温度矩阵判断检测到的对象是否为活体。
- 只有在 **人脸识别成功** 且 **红外活体检测成功** 的情况下才允许写入考勤记录。

最终判断逻辑：

```text
人脸识别成功 && 活体检测成功 => 考勤成功
人脸识别失败 || 活体检测失败 => 拒绝考勤
```

### 2.2 阶段目标

第一阶段目标：

```text
先不考虑摄像头人脸框和温度矩阵坐标对应关系。
只根据 32×24 温度矩阵中满足人体温度条件的数据点数量判断是否存在活体。
```

第二阶段目标：

```text
根据摄像头识别到的人脸框，推算人脸在 MLX90640 温度阵列中的对应范围。
只在人脸对应的温度区域中判断是否满足活体条件。
```

---

## 3. 系统总体架构

### 3.1 硬件组成

系统硬件包括：

- 摄像头：用于采集可见光图像，供昇腾人脸检测与识别使用。
- 昇腾 310 或相关开发板：用于运行人脸检测、人脸识别模型。
- STM32F103：用于读取 MLX90640 温度阵列，并通过串口输出数据。
- MLX90640：红外热成像传感器，输出 `32×24` 温度阵列。
- OrangePi / Linux 主控端：运行 Python 后端、Flask 服务、人脸识别逻辑和活体检测逻辑。

### 3.2 软件组成

软件模块包括：

- 摄像头采集模块：负责可见光图像读取。
- 人脸检测模块：负责输出人脸框。
- 人脸识别模块：负责输出用户身份和相似度。
- 串口接收模块：负责读取 STM32F103 输出的温度矩阵。
- 红外活体检测模块：负责判断温度矩阵中是否存在活体特征。
- 考勤模块：负责在验证通过后写入数据库。
- Web 前端模块：负责显示用户、考勤记录和摄像头画面。

### 3.3 数据流

```text
摄像头
  ↓
可见光图像
  ↓
昇腾人脸检测与识别
  ↓
输出人脸框、用户 ID、相似度

STM32F103 + MLX90640
  ↓
串口输出 32×24 温度矩阵
  ↓
Python 串口解析
  ↓
输出 thermal_matrix

人脸识别结果 + thermal_matrix
  ↓
活体检测判断
  ↓
考勤写入或拒绝
```

---

## 4. MLX90640 温度数据格式设计

### 4.1 温度矩阵尺寸

MLX90640 输出分辨率为：

```text
32 × 24 = 768 个温度点
```

在 Python 中建议统一表示为：

```python
thermal_matrix.shape == (24, 32)
```

即：

- 行数：24，对应 y 方向。
- 列数：32，对应 x 方向。

### 4.2 串口数据建议格式

STM32F103 可以输出一帧完整的 768 个温度值。推荐串口格式如下：

```text
FRAME_START
25.1,25.2,25.3,...,26.0
...
FRAME_END
```

或者输出单行：

```text
T:25.1,25.2,25.3,...,26.0
```

Python 端解析后转换为：

```python
thermal_values = [float(x) for x in line.split(",")]
thermal_matrix = np.array(thermal_values, dtype=np.float32).reshape(24, 32)
```

### 4.3 温度数据缓存

建议串口模块独立线程运行，持续读取最新温度矩阵，并缓存最近一帧：

```python
class ThermalReader:
    def __init__(self):
        self.latest_frame = None
        self.lock = threading.Lock()

    def get_latest_frame(self):
        with self.lock:
            if self.latest_frame is None:
                return None
            return self.latest_frame.copy()
```

这样人脸识别模块需要活体检测时，直接读取最新一帧温度矩阵即可。

---

## 5. 第一阶段方案：基于 768 个温度点数量的简单活体检测

### 5.1 设计思想

第一阶段先不考虑摄像头人脸框与红外矩阵坐标之间的映射关系。

只判断整帧 `32×24` 温度矩阵中有多少个点满足人体温度条件。

如果满足条件的数据点数量达到设定阈值，就认为当前画面中存在活体。

判断逻辑：

```text
统计 768 个温度点中满足人体温度范围的数据点数量
如果数量超过阈值，则判定为活体
否则判定为非活体
```

### 5.2 为什么先做简单方案

先做简单方案有几个好处：

- 实现速度快。
- 不需要摄像头和红外传感器坐标标定。
- 可以快速验证 MLX90640 数据是否稳定可用。
- 可以快速接入现有人脸识别流程，形成完整闭环。
- 后续可以在此基础上逐步升级到人脸区域温度判断。

### 5.3 温度阈值设计

人体脸部皮肤温度通常低于标准体温，常见范围约为：

```text
30℃ ~ 36.5℃
```

考虑环境、距离、传感器误差和人体差异，初始建议使用较宽范围：

```text
30.0℃ <= temperature <= 38.5℃
```

同时，为了减少环境高温误判，需要和背景温度比较：

```text
temperature - ambient >= 3.0℃
```

其中 `ambient` 使用整帧温度中位数估计：

```python
ambient = np.median(thermal_matrix)
```

### 5.4 有效温度点统计

有效温度点定义：

```text
温度在人体合理范围内，并且明显高于背景温度的点
```

代码逻辑：

```python
valid_mask = (
    (thermal_matrix >= 30.0) &
    (thermal_matrix <= 38.5) &
    (thermal_matrix - ambient >= 3.0)
)

valid_count = np.sum(valid_mask)
```

### 5.5 活体数量阈值

MLX90640 分辨率较低，人体脸部在矩阵中可能只占几十个点。

初始建议：

```text
valid_count >= 20 => 判定存在活体
```

根据实际距离可以调整：

| 距离 | 人脸占用点数估计 | 建议阈值 |
|---|---:|---:|
| 近距离 30cm ~ 50cm | 较大 | 30 ~ 60 |
| 中距离 50cm ~ 100cm | 中等 | 15 ~ 30 |
| 远距离 100cm 以上 | 较小 | 8 ~ 20 |

建议初始值：

```text
valid_count_threshold = 20
```

### 5.6 连续多帧确认

单帧判断容易受噪声、热源干扰影响。

建议使用连续多帧判断：

```text
最近 5 帧中至少 3 帧满足活体条件，才判定活体通过。
```

例如：

```python
history = [True, False, True, True, False]
sum(history) >= 3 => 活体通过
```

### 5.7 第一阶段活体检测函数

```python
import numpy as np

def simple_liveness_check(
    thermal_matrix,
    min_temp=30.0,
    max_temp=38.5,
    delta_temp=3.0,
    min_valid_points=20
):
    if thermal_matrix is None:
        return False, {
            "reason": "no thermal frame"
        }

    ambient = float(np.median(thermal_matrix))

    valid_mask = (
        (thermal_matrix >= min_temp) &
        (thermal_matrix <= max_temp) &
        ((thermal_matrix - ambient) >= delta_temp)
    )

    valid_count = int(np.sum(valid_mask))
    max_temperature = float(np.max(thermal_matrix))
    mean_temperature = float(np.mean(thermal_matrix))

    is_live = valid_count >= min_valid_points

    return is_live, {
        "ambient": ambient,
        "valid_count": valid_count,
        "max_temperature": max_temperature,
        "mean_temperature": mean_temperature,
        "min_valid_points": min_valid_points
    }
```

### 5.8 第一阶段系统集成方式

原本考勤逻辑：

```python
if best_match and max_sim > threshold:
    database.add_attendance(user_id, 'camera_auto', filename)
```

加入活体检测后：

```python
thermal_matrix = thermal_reader.get_latest_frame()
is_live, live_info = simple_liveness_check(thermal_matrix)

if best_match and max_sim > threshold and is_live:
    database.add_attendance(user_id, 'camera_auto', filename)
else:
    print("识别成功但活体检测失败，拒绝考勤")
```

### 5.9 第一阶段优点

- 实现简单。
- 不依赖复杂标定。
- 可以快速形成可演示系统。
- 对普通照片和屏幕照片有一定防护效果。

### 5.10 第一阶段缺点

- 热水杯、手掌、加热物体可能误触发。
- 只知道画面中存在热源，不知道热源是否在人脸位置。
- 如果背景中有高温物体，可能误判为活体。
- 多人场景下无法确认温度对应的是哪一个人。

---

## 6. 第二阶段方案：基于人脸框映射的温度区域活体检测

### 6.1 设计思想

第二阶段不再判断整帧 `32×24` 温度矩阵，而是只判断摄像头识别到的人脸对应的温度区域。

基本流程：

```text
摄像头检测人脸框
  ↓
得到人脸中心点或人脸 ROI
  ↓
通过标定映射到 MLX90640 32×24 温度矩阵
  ↓
取映射点附近 3×3、5×5 或 7×7 温度区域
  ↓
判断该区域是否满足人体脸部温度特征
```

### 6.2 为什么需要坐标映射

摄像头和 MLX90640 不在同一个位置，二者视角不同。

因此不能直接用比例换算：

```text
thermal_x = camera_x / camera_width * 32
thermal_y = camera_y / camera_height * 24
```

这种简单缩放只有在摄像头和红外传感器视角完全重合时才比较有效。

实际情况是：

- 摄像头和红外传感器有物理间距。
- 两者视场角不同。
- 安装角度可能不同。
- 人距离设备远近会影响对应关系。

因此需要做一次标定，建立：

```text
摄像头坐标 -> 红外矩阵坐标
```

的映射关系。

### 6.3 标定前提

标定前需要保证：

- 摄像头和 MLX90640 固定在同一个支架上。
- 两者相对位置不能再移动。
- 标定时人与设备距离尽量接近实际使用距离。
- 实际使用时人脸大致处于设备前方固定范围内。

### 6.4 标定点采集方法

使用一个明显热源，例如：

- 手掌。
- 额头。
- 热水杯。

让热源分别出现在摄像头画面中的几个位置：

- 左上。
- 右上。
- 左下。
- 右下。
- 中心。
- 可选：左中、右中、上中、下中。

每个位置记录两个坐标：

1. 摄像头画面中的热源中心坐标。
2. MLX90640 温度矩阵中的最高温点坐标。

示例：

| 标定点 | 摄像头坐标 `(camera_x, camera_y)` | 红外矩阵坐标 `(thermal_x, thermal_y)` |
|---|---:|---:|
| 左上 | `(120, 80)` | `(6, 4)` |
| 右上 | `(520, 80)` | `(26, 5)` |
| 左下 | `(120, 400)` | `(7, 19)` |
| 右下 | `(520, 400)` | `(25, 18)` |
| 中心 | `(320, 240)` | `(16, 12)` |

### 6.5 映射模型选择

由于 MLX90640 只有 `32×24`，分辨率较低，推荐先使用二维单应性映射：

```python
H, _ = cv2.findHomography(camera_points, thermal_points)
```

后续如果发现误差较大，可以改用：

- 仿射变换。
- 多项式拟合。
- 分区查表插值。
- 深度相关的多距离标定。

第一版建议使用 `findHomography`，实现简单且够用。

### 6.6 映射矩阵计算代码

```python
import cv2
import numpy as np

camera_points = np.float32([
    [120, 80],
    [520, 80],
    [120, 400],
    [520, 400],
    [320, 240],
])

thermal_points = np.float32([
    [6, 4],
    [26, 5],
    [7, 19],
    [25, 18],
    [16, 12],
])

H, _ = cv2.findHomography(camera_points, thermal_points)
```

建议将 `H` 保存到 JSON 文件中：

```json
{
  "homography": [
    [0.0412, 0.0015, 1.203],
    [0.0008, 0.0395, 0.921],
    [0.00001, 0.00002, 1.0]
  ]
}
```

文件名建议：

```text
thermal_calibration.json
```

### 6.7 摄像头坐标映射到红外矩阵坐标

```python
def map_camera_to_thermal(x, y, H):
    point = np.array([[[x, y]]], dtype=np.float32)
    mapped = cv2.perspectiveTransform(point, H)
    tx, ty = mapped[0][0]

    tx = int(round(tx))
    ty = int(round(ty))

    tx = max(0, min(31, tx))
    ty = max(0, min(23, ty))

    return tx, ty
```

### 6.8 根据人脸框确定检测点

摄像头人脸框：

```python
x1, y1, x2, y2 = face_box
```

可以先使用人脸中心点：

```python
face_cx = (x1 + x2) / 2
face_cy = (y1 + y2) / 2
```

也可以偏向人脸上半部分，因为额头和脸颊更适合作为温度检测区域：

```python
face_cx = (x1 + x2) / 2
face_cy = y1 + (y2 - y1) * 0.45
```

不建议取太靠上的点，因为可能落到头发区域。

推荐初始值：

```text
人脸框 x 方向中心
人脸框 y 方向 45% 高度位置
```

### 6.9 红外 ROI 区域选择

映射得到：

```python
tx, ty = map_camera_to_thermal(face_cx, face_cy, H)
```

由于 MLX90640 分辨率低，不建议只取单个点。

推荐取：

```text
5×5 ROI
```

即：

```python
roi = thermal_matrix[ty-2:ty+3, tx-2:tx+3]
```

为了避免越界，需要封装函数：

```python
def get_thermal_roi(thermal_matrix, tx, ty, radius=2):
    h, w = thermal_matrix.shape

    x1 = max(0, tx - radius)
    x2 = min(w, tx + radius + 1)
    y1 = max(0, ty - radius)
    y2 = min(h, ty + radius + 1)

    return thermal_matrix[y1:y2, x1:x2]
```

### 6.10 ROI 温度特征

在 ROI 中建议计算：

- 最高温度 `max_temp`。
- 平均温度 `mean_temp`。
- 90% 分位温度 `p90_temp`。
- 背景温度 `ambient`。
- 人脸区域与背景温差 `p90_temp - ambient`。

推荐主要使用：

```text
p90_temp
```

原因：

- 单个最高温点可能是噪声。
- 平均值容易被背景低温点拉低。
- 90% 分位温度能够代表 ROI 中较热区域，同时比最高值稳定。

### 6.11 基于人脸 ROI 的活体判断条件

建议初始条件：

```text
30.0℃ <= p90_temp <= 38.5℃
p90_temp - ambient >= 3.0℃
```

代码：

```python
def face_roi_liveness_check(thermal_matrix, tx, ty):
    roi = get_thermal_roi(thermal_matrix, tx, ty, radius=2)

    if roi.size == 0:
        return False, {
            "reason": "empty roi"
        }

    ambient = float(np.median(thermal_matrix))
    p90_temp = float(np.percentile(roi, 90))
    max_temp = float(np.max(roi))
    mean_temp = float(np.mean(roi))

    is_live = (
        30.0 <= p90_temp <= 38.5 and
        p90_temp - ambient >= 3.0
    )

    return is_live, {
        "ambient": ambient,
        "p90_temp": p90_temp,
        "max_temp": max_temp,
        "mean_temp": mean_temp,
        "delta": p90_temp - ambient
    }
```

### 6.12 第二阶段优点

- 能确认热源是否位于人脸附近。
- 能减少热水杯、手掌等背景热源误判。
- 与人脸识别结果强绑定，安全性更高。
- 更适合最终项目展示和答辩说明。

### 6.13 第二阶段限制

- 需要做标定。
- 摄像头和红外传感器固定后不能随意移动。
- 人距离变化过大时，映射可能产生偏差。
- MLX90640 分辨率较低，不能期待像普通热成像仪一样精确。

---

## 7. 活体检测与考勤流程设计

### 7.1 第一阶段流程

```text
读取摄像头帧
  ↓
检测人脸
  ↓
提取人脸特征
  ↓
匹配用户
  ↓
读取最新 thermal_matrix
  ↓
统计 768 点中满足人体温度条件的点数
  ↓
人脸识别通过 && 温度点数量达标
  ↓
写入考勤
```

### 7.2 第二阶段流程

```text
读取摄像头帧
  ↓
检测人脸框 face_box
  ↓
提取人脸特征并匹配用户
  ↓
读取最新 thermal_matrix
  ↓
将 face_box 中心映射到 MLX90640 坐标
  ↓
取 5×5 温度 ROI
  ↓
计算 p90 温度和背景温差
  ↓
人脸识别通过 && ROI 温度达标
  ↓
写入考勤
```

### 7.3 防重复考勤

人脸识别与活体检测成功后，还需要防止连续重复考勤。

建议逻辑：

```text
同一个用户当天只允许自动考勤一次
```

或者：

```text
同一个用户 24 小时内只允许自动考勤一次
```

代码示例：

```python
last_time = self.last_attendance.get(user_id, 0)
now = time.time()

if now - last_time < 24 * 60 * 60:
    print("该用户今天已经考勤，跳过")
    return

database.add_attendance(user_id, 'camera_auto', filename)
self.last_attendance[user_id] = now
```

---

## 8. 阈值调试建议

### 8.1 推荐初始阈值

| 参数 | 初始值 | 说明 |
|---|---:|---|
| `min_temp` | `30.0℃` | 人脸皮肤温度下限 |
| `max_temp` | `38.5℃` | 人体温度合理上限 |
| `delta_temp` | `3.0℃` | 相比背景温度至少高 3℃ |
| `min_valid_points` | `20` | 第一阶段有效温度点数量阈值 |
| `roi_radius` | `2` | 第二阶段取 5×5 温度区域 |
| `face_similarity_threshold` | `0.5` | 人脸识别相似度阈值，按现有系统调整 |

### 8.2 不同环境下的调整

室温较低时：

```text
delta_temp = 4.0℃ ~ 6.0℃
```

室温较高时：

```text
delta_temp = 2.0℃ ~ 3.0℃
```

人距离较远时：

```text
min_valid_points 可以适当降低
ROI 可以从 5×5 改为 3×3
```

人距离较近时：

```text
min_valid_points 可以适当提高
ROI 可以从 5×5 改为 7×7
```

---

## 9. 测试方案

### 9.1 第一阶段测试

测试项目：

- 无人场景。
- 真人站在设备前。
- 真人远离设备。
- 手掌靠近设备。
- 热水杯靠近设备。
- 手机照片靠近摄像头。
- 纸质照片靠近摄像头。

期望结果：

| 测试场景 | 期望结果 |
|---|---|
| 无人 | 活体失败 |
| 真人 | 活体通过 |
| 手机照片 | 活体失败 |
| 纸质照片 | 活体失败 |
| 热水杯 | 第一阶段可能误判，需要第二阶段优化 |
| 手掌 | 第一阶段可能误判，需要第二阶段优化 |

### 9.2 第二阶段测试

测试项目：

- 真人脸部正对摄像头。
- 真人偏左。
- 真人偏右。
- 真人偏上。
- 真人偏下。
- 热水杯放在人脸框外。
- 手掌放在人脸框外。
- 手机照片放在人脸框内。
- 纸质照片放在人脸框内。

期望结果：

| 测试场景 | 期望结果 |
|---|---|
| 真人脸部在框内 | 活体通过 |
| 热源在人脸框外 | 活体失败 |
| 手机照片 | 活体失败 |
| 纸质照片 | 活体失败 |
| 人脸识别成功但 ROI 温度不达标 | 拒绝考勤 |

---

## 10. 六天开发计划

### 第 1 天：串口温度数据接入与解析

目标：

```text
在 Python 中稳定获取 STM32F103 输出的 MLX90640 32×24 温度矩阵。
```

任务：

- 确认 STM32F103 串口输出格式。
- 编写 Python 串口读取模块。
- 将 768 个温度点解析为 `(24, 32)` 矩阵。
- 打印每帧温度统计信息：
  - 最高温。
  - 最低温。
  - 平均温。
  - 中位温。
- 增加异常处理，避免串口数据半帧、乱码、丢帧导致程序崩溃。

交付：

```text
thermal_matrix.shape == (24, 32)
能够持续稳定输出温度矩阵
```

---

### 第 2 天：完成第一阶段 768 点简单活体检测

目标：

```text
根据 32×24 全矩阵中满足人体温度条件的数据点数量判断是否存在活体。
```

任务：

- 实现 `simple_liveness_check()`。
- 设置初始温度阈值：
  - `30.0℃ <= temperature <= 38.5℃`
  - `temperature - ambient >= 3.0℃`
- 统计 `valid_count`。
- 设置 `valid_count >= 20` 判定为活体。
- 加入连续多帧确认机制。
- 输出调试日志：
  - `ambient`
  - `valid_count`
  - `max_temperature`
  - `is_live`

交付：

```text
真人靠近时活体通过
无人时活体失败
照片和屏幕图片通常无法通过温度检测
```

---

### 第 3 天：接入昇腾人脸识别考勤流程

目标：

```text
将第一阶段活体检测接入现有人脸识别系统。
```

任务：

- 在人脸识别成功后读取最新温度矩阵。
- 调用 `simple_liveness_check()`。
- 修改考勤写入条件：

```text
人脸识别成功 && 活体检测成功 => 写入考勤
```

- 保留防重复考勤逻辑。
- 在日志中输出：
  - 用户 ID。
  - 用户名。
  - 人脸相似度。
  - 活体检测结果。
  - 有效温度点数量。

交付：

```text
系统形成第一版完整闭环：人脸识别 + 简单红外活体检测 + 考勤
```

---

### 第 4 天：摄像头与 MLX90640 坐标标定

目标：

```text
建立摄像头坐标到 MLX90640 32×24 温度矩阵坐标的映射关系。
```

任务：

- 固定摄像头和 MLX90640 相对位置。
- 使用热源采集至少 5 个标定点。
- 记录每个点的摄像头坐标和红外矩阵坐标。
- 使用 OpenCV 计算单应矩阵 `H`。
- 将标定矩阵保存为 `thermal_calibration.json`。
- 编写 `map_camera_to_thermal()` 函数。

交付：

```text
输入摄像头坐标，可以得到对应的 MLX90640 矩阵坐标
```

---

### 第 5 天：实现基于人脸框的温度 ROI 活体检测

目标：

```text
从整帧 768 点判断升级为只判断人脸对应温度区域。
```

任务：

- 获取人脸框 `(x1, y1, x2, y2)`。
- 计算人脸温度检测点：

```text
face_cx = 人脸框中心 x
face_cy = 人脸框高度 45% 位置
```

- 将该点映射到 MLX90640 坐标 `(tx, ty)`。
- 取 `5×5` 温度 ROI。
- 计算 ROI 的：
  - `p90_temp`
  - `max_temp`
  - `mean_temp`
  - `ambient`
  - `delta`
- 使用 ROI 活体条件：

```text
30.0℃ <= p90_temp <= 38.5℃
p90_temp - ambient >= 3.0℃
```

交付：

```text
系统只根据人脸附近温度判断活体，降低背景热源误判
```

---

### 第 6 天：系统联调、阈值优化与验收

目标：

```text
完成最终系统联调，使系统可以稳定完成人脸识别和红外活体考勤。
```

任务：

- 测试真人考勤。
- 测试照片攻击。
- 测试手机屏幕攻击。
- 测试热水杯干扰。
- 测试手掌干扰。
- 测试不同距离和角度。
- 根据测试结果调整：
  - `min_temp`
  - `max_temp`
  - `delta_temp`
  - `min_valid_points`
  - `roi_radius`
- 整理日志输出。
- 整理代码注释。
- 固化最终参数。

交付：

```text
最终系统具备：
人脸识别
红外活体检测
防重复考勤
考勤记录写入
异常日志输出
```

---

## 11. 最终推荐实现策略

最终系统建议保留两套活体检测方式：

### 11.1 简单模式

适用于：

- 快速演示。
- 无法完成标定时。
- 系统初期调试。

判断方式：

```text
768 个温度点中达到人体温度条件的点数超过阈值
```

### 11.2 精确模式

适用于：

- 最终项目展示。
- 实际考勤系统。
- 需要降低误判的场景。

判断方式：

```text
根据人脸框映射到红外温度矩阵，只判断人脸对应区域温度
```

### 11.3 最终考勤判断

推荐最终条件：

```python
attendance_allowed = (
    face_recognition_success and
    liveness_success and
    not repeated_attendance
)
```

---

## 12. 结论

本项目建议采用由简到难的实现路线。

第一阶段先使用 `32×24=768` 个温度点的数量统计方法，实现最小可用版本：

```text
只要达到人体温度条件的数据点数量超过阈值，就判定存在活体。
```

该方案实现简单，适合快速接入现有昇腾人脸识别系统。

第二阶段再引入摄像头与 MLX90640 的坐标标定，将摄像头检测到的人脸框映射到温度矩阵中的对应区域：

```text
只判断人脸附近的温度 ROI 是否满足人体温度特征。
```

这样可以显著降低热水杯、手掌、环境热源等干扰造成的误判，更适合作为最终系统方案。

最终系统应满足：

```text
人脸识别成功
红外活体检测成功
非重复考勤
```

三项条件同时成立时，才写入考勤记录。

