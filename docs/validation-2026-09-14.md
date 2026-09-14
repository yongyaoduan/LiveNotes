# LiveNotes 真实课堂录音验证 · 2026-09-14

用户报告的重复字幕已复现。测试直接读取用户的 5618、5047 原录音，不使用合成语音。对两份录音开头各取原音约 150 秒，以 ffmpeg `atempo=1.25` 保持音高加速为 120 秒，再每 100 ms 按墙钟实时投送音频。

使用与生产相同的 `timeIndexedProgressiveTranscription`、`SpeechAnalyzerLiveInputConverter`、`SpeechAnalyzerTranscriptUpdate` 和 `SpeechAnalyzerTranscriptAssemblyStore`。保存每个原生事件、逐事件临时字幕/已提交字幕快照和最终稿。先用原代码实跑，再将同一组原始事件回放到修复后的组装器，排除识别器多次运行的随机差异。

## 对照结果

| 真实音源 | 播放速度 / 测试长度 | 原生最终结果 | 修复前保存 | 修复后保存 | 应用额外插入词数（前 → 后） |
| --- | --- | ---: | ---: | ---: | ---: |
| `5618/w06/5618_tut6.m4a` | 1.25× / 120 秒 | 37 条、348 词 | 47 条、464 词 | 37 条、348 词 | 116 → 0 |
| `5047/final/week06/5047_lec6.m4a` | 1.25× / 120 秒 | 31 条、291 词 | 52 条、490 词 | 31 条、291 词 | 199 → 0 |
| 同一 5047 原音第 10:00 起 | 1.5× / 90 秒 | 19 条、161 词 | 31 条、239 词 | 19 条、161 词 | 78 → 0 |

这三组共 1,085 个真实识别事件，合计实时投送 5.5 分钟。第三组在初次修复后换片段直接实跑，再用原版/最终修复版分别回放其事件。它进一步复现了一个外层时间边界问题：临时 `special` 范围 0–7.788 秒，最终 `special.` 范围 6–7.8 秒，但实际词时间为 6–7.74 秒。最终判断补充检查词时间范围，避免外层多出 12 ms 就留下重复。

最终修复后在每次原生 final 事件后，已提交字幕都与截至当时的原生最终结果逐条一致，临时字幕中没有残留旧假设；结束保存后仍一致。相对于原生最终结果，新增词与缺失词均为零。测试还检查真实的分时重复语句、未完成后半句、相邻/重叠片段、短句修正和停止时尾句保留。

首次识别事件分别在约 1.04 秒和 1.01 秒到达；这是测试工具收到事件的时间，不是界面/译文延迟。本次修复不增加等待窗口或二次识别。

## 原因与修复

原生临时事件经常只有一个带时间的整句 run，其范围包括句前/句后空白。最终事件带更精确的词时间，时间段变短，而且会同时修改多个词。旧代码只接受很有限的文本差异，于是将旧假设和最终修正版都保存。

例如 5618 中 `So if you are still stuck...` 的临时范围为 18.24–28.8975625 秒，最终范围为 18.24–28.68 秒。修正版同时补出停顿词并修改 `SQ`、`U` 等，超出旧规则允许的差异；5047 的短句和大幅修订更加频繁。

现在先恢复可定位的前后半句，再根据原生整句时间属性替换被最终结果覆盖的粗略假设。不对全文做相似句删除，不修改识别器最终词语。没有时间属性的旧输入保留原有保守匹配逻辑。

## 复现

在仓库根目录执行；完整音频和测试产物留在被 git 忽略的 `.cache/real-audio-validation/`。回归 fixture 只保存识别事件，不包含原音频。

```bash
mkdir -p .cache/real-audio-validation
xcrun swiftc -swift-version 6 -parse-as-library -O \
  -o .cache/real-audio-validation/benchmark-fixed \
  LiveNotesCore/Sources/LiveNotesCore/*.swift scripts/benchmark-real-audio.swift
ffmpeg -v error -y -i ../5618/w06/5618_tut6.m4a \
  -t 120 -af atempo=1.25 .cache/real-audio-validation/5618-fast.wav
.cache/real-audio-validation/benchmark-fixed \
  .cache/real-audio-validation/5618-fast.wav \
  .cache/real-audio-validation/5618-new live
python3 scripts/summarize-real-audio-benchmark.py \
  .cache/real-audio-validation/5618-new
swift test --package-path LiveNotesCore
```

工具 `replay` 模式接收它保存的 `*-events.json`，按原顺序重放。对照产物前缀为 `5618-before` / `5618-final`、`5047-before` / `5047-final`、`5047-150pct-before` / `5047-150pct-final`。第三组音频用 `ffmpeg -ss 600 -i ../5047/final/week06/5047_lec6.m4a -t 90 -af atempo=1.5` 提取。

## 验证范围

以上数字衡量应用是否额外重复/丢失原生识别结果，不是对原音频的词错误率。5047 的原生最终稿仍有明显错词；专业术语、口音、教室远场收音的准确率问题仍存在，不能据此宣称整体识别质量已经合格。

上述第一阶段仅将文件按实时节奏送入生产转换/组装路径，不覆盖扬声器→麦克风、翻译和界面；后续声学及 XCUITest 验证见下文。所有阶段均未改写用户历史录音或历史稿件，也未验证整节课连续运行。

107 项核心测试通过，macOS 应用 `xcodebuild build` 通过。


## 后续：实际扬声器播放、麦克风录音与录屏

用户要求追加实际使用验收后，使用 MacBook Air Speakers 播放同一 5618 1.25× 音源，由 MacBook Air Microphone 和 Release 应用录音，同时保存完整桌面录像。

第一轮音源 120 秒，应用实际录音 144.4 秒，保存 37 条原文、37 条译文。录屏 165.408 秒，共 9,349 帧；逐帧解码字幕/控件区域，按二值文字区域去重后对 5,289 个不同画面执行本地 Vision OCR，逐帧索引和 OCR 结果均保存在 `.cache/acoustic-validation/5618-first-frames/`。重复六词序列筛查无命中，但这不证明短片段没有重复：界面和保存稿核对确实发现 `Find` 与后面的 `Find it...` 同时保留。

原因是临时片段与最终结果首尾都发生移动，最终结果不再严格包含于临时范围。新判断在确实带有整句粗时间属性的假设上，要求重叠超过较短范围的一半；轻微重叠的不同语句仍保留，能准确定位的前后半句仍先拆分保留。这是一条根据实录增加的范围判断，不是全局相似句删除。

另做一轮带临时本地诊断的实播，保存 205 个原始麦克风识别事件，其中有 22 条非空最终结果和一个空结果。原判断保存 25 条；最终判断对同一批事件回放保存 22 条、191 词，与原生非空最终结果逐条一致，没有额外词或缺失词。回归 fixture 为 `native-speech-classroom-acoustic-results.json`。临时诊断代码随后已从正式源码移除。

逐帧复核还发现并修复：

- 已经有实时字幕时，低电平音频不应显示“Waiting for speech”；显示“Transcribing”，暂停时显示“Paused”。
- 结束保存按钮在系统背景窗口样式下对比度不足；使用明确的红底白字，避免随系统强调色退化为黑底黑字或浅底白字。

本地声学证据不作为公开 release 附件上传。最终候选版的 XCUITest 验收结果如下。

## XCUITest 声学验收复现方式

已有的 `testProductionLoopbackRecordsTranscribesSavesAndExports` 可以通过扬声器实播课程、生产麦克风捕获、Apple 原生识别/翻译、界面保存与导出完成自动化检查。这里 `loopback` 是脚本模式名，设备明确指定为实体扬声器和麦克风：

```bash
LIVENOTES_E2E_AUDIO_SOURCE="$PWD/.cache/real-audio-validation/5618-fast.wav" \
LIVENOTES_E2E_CLIP_SECONDS=120 \
LIVENOTES_E2E_MIN_DURATION_SECONDS=110 \
LIVENOTES_E2E_EXPECTED_PHRASE='my agent' \
LIVENOTES_E2E_MODE=loopback \
LIVENOTES_TEST_AUDIO_INPUT='MacBook Air Microphone' \
LIVENOTES_TEST_AUDIO_OUTPUT='MacBook Air Speakers' \
  scripts/run-loopback-e2e-test.sh
```

测试使用隔离的 session store，不修改用户已有课堂笔记；保存录音必须可解码、达到预期时长且有实际音量，导出 Markdown 必须包含全部保存的原文/译文，导出音频必须与保存音频逐字节一致。原生端到端证据位于 `dist/native-e2e/LiveNotes.xcresult`，连续多轮前需复制保留该目录。

5047 首轮声学测试因原生识别将 `iPhone` 误识别而未通过关键词断言，失败 xcresult、录屏、实时快照保留在 `.cache/xcuitest-acoustic/5047-iphone-failure-*`。此失败不计为通过，也不解释为字幕组装重复；后续改用同片段的 `Steve Jobs` 核对完整保存/导出路径。术语识别准确率仍是已知限制。


## 最终实播结果

| 课程 | 音源长度 | 保存录音 | 保存原文 / 译文 | 保存耗时 | 导出文件就绪 | 录像逐帧解码 / OCR 文字画面 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 5618 · 1.25× | 120 秒 | 135.2 秒 | 34 / 34 条 | 1.84 秒 | 1.55 秒 | 6,185 / 2,331 |
| 5047 · 1.25× | 120 秒 | 约 130 秒 | 25 / 25 条 | 1.97 秒 | 1.51 秒 | 4,653 / 2,221 |

两次 `testProductionLoopbackRecordsTranscribesSavesAndExports` 均通过。录音比音源略长，包含启动、结束和界面操作时的环境声。完整视频、XCTest 结果、音频、逐帧索引、OCR 结果与导出副本位于 `.cache/xcuitest-acoustic/` 的 `5618-*` 和 `5047-*` 路径。

合计 10,838 帧均解码检查，自适应文字掩码去重后的 4,552 个画面全部 OCR；重复六词片段筛查为零。5618 / 5047 分别有 116 / 117 次实时字幕快照，已提交文本末尾与预览开头的三词及以上重叠均为零。另核对保存稿、字幕提交/滚动、结束确认、保存、导出的关键画面，以及短句范围修正回归用例。这个筛查不会证明所有语言学重复都不存在，也不是逐帧人工逐字阅读；XCUITest 系统遮罩会遮挡局部画面，已结合无遮挡 XCTest 窗口截图和实时快照复核。

5047 第二次尝试还复现测试代码的读取竞态：预览从界面移除后，旧的 `exists → value` 读取发生失败。改为一次不可变 accessibility snapshot 后，完整重跑通过；同时在 teardown 停止播放进程，超时播放明确判为失败。失败证据保留为 `5047-snapshot-race-*`。

确认字幕残留修复后，移除三个没有生产调用的旧实现：`LiveTranscriptSegmentBuffer`、`LiveTranscriptPreviewDisplayPolicy`、`TranscriptCoverage`，以及仅测试这些旧实现的九项用例。保留生产组装器、四份真实事件 fixture 和当前保存/恢复路径。


帧分析初版的固定亮度阈值会把 XCUITest 遮罩下的一部分变化合并，因此发布前改用局部自适应阈值，重新解码两份完整视频并对全部 4,552 个不同画面 OCR。上表和最终结论采用重跑结果，对应 `5618-adaptive-frames` / `5047-adaptive-frames`。从中能够定位原文与预览边界的 969 / 1,062 个画面另做短句及三词以上衔接重复筛查，均无命中；仍保留 OCR 遮挡与错字的限制。

## 发布包完整回归

清理后 98 项核心测试全部通过。对 `build-homebrew-app-zip.sh` 生成的 **1.0.2 实际应用包**，使用修改 `UITargetAppPath` 的 xctestrun 执行 `test-without-building`，完整 42 项 XCUITest 在 532.2 秒内全部通过，不是仅测试另一个开发构建。完整录屏和 48 张无遮挡窗口截图位于 `dist/ui-evidence/`；已复核六页截图概览及真实音频的保存/导出结果。

完整套件中的生产端到端测试再次实播 5047 · 1.25×，保存约 1.85 秒，导出文件约 1.47 秒就绪。`check-release-readiness.sh` 通过，压缩包每个文件都与实际受测应用逐一比对一致。

发布产物：`LiveNotes-1.0.2.zip`，SHA-256：

```text
12434b75ba9eabd11137001c8e6ead1487f39786a3ec5ad2cd081bf3424e8fd8
```

Homebrew 生成器和发布检查改为当前支持的 `depends_on macos: :tahoe`，避免旧字符串声明的弃用警告；相关脚本测试通过。本轮完整发布验证在本机执行。历史远端运行 `33954000416` 在原生识别阶段报 `Local transcription failed`；不把这次本机通过写成远端 CI 通过。

早期手动验收创建的三条 QA 记录及其音频已归档至 `.cache/xcuitest-acoustic/manual-qa-archive/`，保留原库备份；其余 28 条记录内容逐条比对未改变。后续 XCUITest 均使用隔离存储。
