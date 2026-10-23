# 評分規則設定重構規劃

<!-- markdownlint-disable MD028 -->
<!-- markdownlint-disable MD033 -->

## 背景

需求方希望能自訂嚴重度分級，且不同框架的規則可以採用不同分級，例如 Spring Boot 3 維持目前的四級，Angular 採用另一套分級。

這次重構把評分規則、嚴重度分級、扣分與等級的定義全部移到 code-review-scoring-rules 專案管理，code-review-scoring 只保留執行方式、報告語言，以及規則專案的位置。評分流程本身不變。

這是破壞性變更，預計發布為 3.0.0。框架才剛發布、還沒有使用者，不需要提供自動搬移，只需要在 setup check 偵測到舊設定時印出說明。

## 已確認的決策

- 規則一律放在 code-review-scoring-rules 專案；code-review-scoring 的 `settings.ini` 只指定該專案的路徑（完整路徑或相對路徑）。
- 刪除 `configs/standards.ini`，原本的內容改放到規則專案根目錄的 `rules.ini`，並新增 `enable="true"` 決定是否啟用該規則。
- 每套規則有自己的設定檔，定義 `applies`、面向配分、嚴重度分級、等級與等級上限。
- 規則專案根目錄有全域預設檔，規則沒有定義的區塊直接採用全域預設。
- 不需要本機覆寫：同一套規則想用不同設定時，建立新的規則。
- 評分途中不接受修改任何規則設定，以步驟 1 的快照與雜湊值鎖定。
- 嚴重度與等級的名稱、數量都可以自訂。
- bash、zsh、PowerShell 的行為仍然必須一致（同仁可能自攜非 Windows 設備）。
- 設定檔格式統一採用 INI。
- `applies`、`role`、`scan` 與面向配分放在各規則的 `rule.ini`，`rules.ini` 只負責登錄與啟用。
- 嚴重度可以另外設定報告上顯示的名稱（例如前端規則使用中文分級）。
- 規則專案現有的 `zh-tw/`、`en/` 子目錄只是示範，規則專案 README 以醒目方式註明規則不需要建立多語言版本。
- 嚴重度採用「必須修正的問題沿用 SonarQube 傳統嚴重度的 Critical／Major／Minor，風格層面的小問題沿用 Google Code Review 指引的 Nit」；規則專案現有規則與 `defaults.ini` 都採用這套分級（見〈嚴重度分級〉）。
- 等級改為 A～F（A、B、C、D、F，沒有 E），預設門檻為 A 95、B 85、C 70、D 60、F 0；等級與嚴重度一樣支援選填的顯示名稱 `name`。
- 撰寫規則的工具（Skill、腳本、模板）不搬到規則專案，所有操作都從評分專案起始（見〈撰寫規則的工具〉）。

## 檔案配置

### code-review-scoring

`configs/settings.example.ini` 保留第 1～31 行（`[workflow]`、平台區段與 `[language]`），刪除第 33 行以後的評分配分說明與範例，新增：

```ini
[rules]
root="C:/Users/me/Documents/code-review-scoring-rules"
```

- `root`：規則專案根目錄，完整路徑或相對於 `configs/` 的路徑。
- setup check 找不到規則專案、`rules.ini` 或全域預設檔時報錯，不能開始評分。
- 刪除 `[points]`、`[deductions]`、`[grades]`；`merge` 移到規則專案的 `[scoring]` 區段（見〈rule.ini〉）。
- setup check 偵測到 `configs/standards.ini` 或上述舊區段時，停下並說明要搬到規則專案的哪個檔案。

### code-review-scoring-rules

```text
code-review-scoring-rules/
├── rules.ini                 規則登錄：每套規則一個區段
├── defaults.ini              全域預設：面向配分、嚴重度分級、等級
├── springboot3-rule/
│   ├── rule.ini              規則設定
│   ├── springboot-3-cr-scoring-rule.md
│   └── springboot-3-cr-scoring-rule.tsv
└── common-rule/
    ├── rule.ini
    ├── common-cr-scoring-rule.md
    └── common-cr-scoring-rule.tsv
```

- 每套規則只有一種語言，現有的 `zh-tw/`、`en/` 子目錄只是示範用，README 要寫明不需要建立多語言版本。
- 檔名：各規則的設定檔為 `rule.ini`，全域預設為 `defaults.ini`。根目錄不用 `configs.ini`，避免和 code-review-scoring 的 `configs/` 混淆。

## 設定檔格式

統一採用 INI，選擇理由見〈設定檔格式的選擇〉。

### rules.ini

```ini
[springboot-3]
path="springboot3-rule"
enable="true"

[common]
path="common-rule"
enable="true"
```

- 區段名稱為規則名稱，沿用目前的命名限制（只能是英數字、`_`、`-`）。
- `path`：規則目錄，即 `rule.ini` 所在的目錄；完整路徑或相對於規則專案根目錄的路徑。
- `enable`：`"true"` 或 `"false"`，必填。停用的規則不參與步驟 1 的分配，lint 仍然檢查。
- 啟用的通用規則最多一套。

### rule.ini

```ini
[rule]
standard="springboot-3-cr-scoring-rule.md"
scan="springboot-3-cr-scoring-rule.tsv"
applies="*.java, *.kt, *.sql, *.xml, *.yml, *.yaml, *.properties, *.gradle, *.kts"

[points]
A="25"
B="15"
C="15"
D="15"
E="10"
F="10"
G="10"

[scoring]
merge="false"

[severity:Critical]
name="嚴重"
points="10"
cap="B"
meaning="資料損毀、資安事件或服務中斷。"

[severity:Major]
points="5"
meaning="特定情境下會出錯，或明顯降低品質。"

[severity:Minor]
points="2"
meaning="能運作，但有更好的寫法。"

[severity:Nit]
points="1"
meaning="風格偏好。"

[grade:A]
name="優"
min="95"

[grade:B]
min="85"

[grade:C]
min="70"

[grade:D]
min="60"

[grade:F]
min="0"
```

- `[rule]`
  - `standard`、`scan`：相對於規則目錄的檔名；`scan` 可省略。
  - `applies`：框架規則必填，寫法沿用目前的 `standards.ini`。
  - `role="common"`：通用規則，不寫 `applies`。
- `[points]`：七個面向合計必須為 100。
- `[scoring]`：`merge` 是否合併扣分，意義與目前 `settings.ini` 的 `[deductions] merge` 相同。
- `[severity:代碼]`：每個嚴重度一個區段，**由上到下為嚴重到不嚴重**。
  - 代碼：規則文件的檢查項、findings.txt 與腳本使用的識別名稱，限英數字、`_`、`-`，避免跨 shell 的編碼問題。
  - `name`：報告上顯示的名稱，選填；未填時顯示代碼。
  - `points`：每筆扣分，必填。
  - `meaning`：意義說明，必填；AI 判斷嚴重度與跨分級對應都依據它。
  - `cap`：出現這個嚴重度的扣分項時，等級上限為哪一個等級；可省略。
  - 最後一個區段是最低級，取代目前綁在 Nit 上的規則：最低級一律可用，diff 無法證實的問題記為最低級。
- `[grade:代碼]`：每個等級一個區段，**由上到下為高到低**。代碼的限制與嚴重度相同，`cap` 引用的是等級代碼。
  - `name`：報告上顯示的名稱，選填；未填時顯示代碼。
  - `min`：最低總分，必填；必須嚴格遞減，最後一級必須是 `0`（讓 AI 與人員知道它是最低等級）。

### defaults.ini

格式與 `rule.ini` 的 `[scoring]`、`[points]`、`[severity:*]`、`[grade:*]` 相同，不含 `[rule]`。

- 以**區塊群組**為單位取代，不逐鍵合併：
  - 規則有任何 `[severity:*]` 區段，就整組取代預設的嚴重度分級。
  - 規則有任何 `[grade:*]` 區段，就整組取代預設的等級。
  - `[scoring]`、`[points]` 各自整個區段取代。
- 規則與預設都沒有定義某個區塊群組時，lint 報錯。

## 評分流程的變更

### lint（standard.sh lint）

- 檢查 `rules.ini`、各規則的 `rule.ini` 與 `defaults.ini`：未知的區段或鍵報錯（避免拼錯被靜默忽略）、必填欄位、配分合計、嚴重度至少一級、等級門檻遞減且最後一級為 0、`cap` 引用的等級存在。
- 規則文件中檢查項的預設嚴重度與「可調整為」，必須是該規則實際生效的分級名稱；目前寫死的四級驗證（`standard.awk:26` 等）改成依設定。
- 「Nit 不需要列在可調整為中」的警告改為針對最低級。
- 通用規則：`meaning` 必填；`[points]`、`[grade:*]`、`cap` 永遠不會被使用，出現時警告。

### 步驟 1（plan、resolve）

- 改由 `rules.ini` 中 `enable="true"` 的規則與各自的 `applies` 分配檔案。
- 快照範圍納入 `rule.ini` 與 `defaults.ini`；`request.md` 與報告記錄的 sha256 涵蓋規則文件與實際生效的設定。

### 步驟 2（CR plugin）

- `prompts/step2.md:34` 不再寫死四級。CR 意見保留 plugin 原本的嚴重度，到步驟 3 依所屬框架的分級，依語意對應到最相近的一級。

### 步驟 3（分析程式碼）

- prompt 帶入該框架規則的嚴重度清單與 `meaning`，取代 `code-analysis/SKILL.md:83` 寫死的說明。
- 通用檢查項先依通用規則的分級判斷，再依語意對應到框架分級；findings.txt 寫框架的分級名稱。建議加上 `from:` 續行記錄原本的通用分級，方便人員審閱。
- 檢查代碼 `-` 的問題與上游因素（U）使用框架分級。
- CR 意見對應後的嚴重度要記錄在 findings.txt，供報告的 CR 統計使用（記錄方式實作時決定）。

### 步驟 4（score）

- 扣分、排序與等級上限改讀實際生效的設定，取代 `score.awk:121`、`score.ps1:141` 的預設值與寫死的 Critical 判斷。
- 嚴重度名稱不在框架分級中時，驗證失敗。

### 步驟 5（報告）

- `render.awk:62` 的排序、`render.awk:129`～`render.awk:138` 的 CR 統計表欄位，改依該份報告的分級動態產生。
- 報告上的嚴重度一律顯示 `name`（未設定時顯示代碼）。
- `labels.tsv` 的 `capped_note` 改為帶入觸發的嚴重度與上限等級。
- 報告模板與 score.json 不再假設等級為 S～D。

### 其他

- `review-state.sh:285`、`review-state.sh:490` 等處寫死的嚴重度名稱與「capped at B」訊息改為依設定。
- 更新 `templates/*/scoring-rule-template.md`、`findings-format.md`、README、notices 與規則專案的 README。
- 更新測試：tests/standards、tests/score、tests/plan、tests/workflow，新增自訂分級（例如五級）與名稱自訂等級的案例。

## 設定檔格式的選擇

需求是把所有設定（含 `meaning`）放在同一個檔案、方便維護，且解析器要能在 awk（bash／zsh）與 Windows PowerShell 5.1 上實作，不依賴外部模組。

| 格式 | 優點 | 風險 |
| --- | --- | --- |
| INI（採用） | 兩種 shell 都已經有 INI 解析的實作，`settings.ini`、`rules.ini` 也是 INI，維護者只需要認得一種格式；逐行解析，區段順序就是檔案順序 | `meaning` 只能寫一行 |
| 限定子集的 YAML | 可讀性好，多行文字方便 | 兩種 shell 都要自己寫依縮排解析的解析器；使用者容易寫出子集以外的語法，必須靠 lint 全面擋下 |
| JSON | PowerShell 5.1 內建 `ConvertFrom-Json` | awk 端要自己寫 JSON 解析器，難度最高；多行文字只能寫 `\n`，不利維護 |
| TOML | `[[severities]]` 很適合表達有序清單 | 兩種 shell 都沒有解析器，實作量與 YAML 相近 |

採用 INI 的理由：

- 目前的嚴重度說明都是一句話，一行足夠；需要更長的判斷依據時，寫在規則文件的「判斷提示」。
- 嚴重度與等級的順序直接取檔案中的書寫順序，不需要額外的排序欄位。
- 若確實需要多行 `meaning`，可以允許同一個鍵重複出現，依序以換行串接。

## 嚴重度分級

主流的分級都依「問題造成的影響」或「是否必須修正」區分，與框架或語言無關。前端與後端的差異，優先以檢查項的預設嚴重度與調整條件表達，不另立分級。自訂分級的彈性保留，但規則專案 README 註明：只有在有明確理由時才覆寫，並把理由寫在規則文件中。

### Google Code Review 指引的分級

Google 的 [How to write code review comments](https://google.github.io/eng-practices/review/reviewer/comments.html) 以前綴標示意見的嚴重度（已對照原文）：

| 標示 | 原文說明 | 作者是否必須處理 |
| --- | --- | --- |
| `Nit:` | This is a minor thing. Technically you should do it, but it won't hugely impact things. | 技術上應該處理 |
| `Optional:` 或 `Consider:` | I think this may be a good idea, but it's not strictly required. | 否 |
| `FYI:` | I don't expect you to do this in this CL, but you may find this interesting to think about for the future. | 否 |

原文沒有定義「無標示」的意見，只提到不加標示時，作者可能把所有意見都當成必須處理。因此本規劃把無標示的意見視為必須修正。

直接套用的問題：

- 只有一級「必須修正」：SQL Injection 與缺少 null 檢查的扣分相同，失去依影響程度區分的能力。
- 等級上限只能掛在「必須修正」上：幾乎每個有問題的 PR 都會被限制在上限以下。
- `Optional`、`FYI` 不需要作者處理，與「每筆扣分項都扣分」的原則衝突；目前這類內容由 findings.txt 的 `N`（不扣分的建議）記錄。

### 分級的出處

沒有單一社群完整使用 Critical／Major／Minor／Nit 這四級，它是兩個來源的組合：

- Critical／Major／Minor：SonarQube 的傳統嚴重度（Blocker／Critical／Major／Minor／Info）。[10.2 起改為 High／Medium／Low](https://docs.sonarsource.com/sonarqube-server/10.2/user-guide/issues)，[SonarQube Cloud 的規則文件](https://docs.sonarsource.com/sonarqube-cloud/standards/managing-rules/rules)仍同時列出兩套；[社群論壇](https://community.sonarsource.com/t/old-issue-types-custom-severities-undeprecated-in-10-8/128860)提到 10.8 恢復傳統嚴重度（未在官方文件中確認）。Review Board 的嚴重度擴充也使用 Major／Minor／Info。
- Nit：[Google Code Review 指引](https://google.github.io/eng-practices/review/reviewer/comments.html)的 `Nit:`，Conventional Comments 也有對應的 nitpick 標籤。

### 採用的分級（已決定）

**必須修正的問題沿用 SonarQube 傳統嚴重度的 Critical／Major／Minor，風格層面的小問題沿用 Google Code Review 指引的 Nit。** 呈報時以這句話說明分級依據。

`defaults.ini` 與規則專案現有規則都採用這套分級：

| 代碼 | 出處 | Google 標示 | 意義 | 處理方式 |
| --- | --- | --- | --- | --- |
| `Critical` | SonarQube | 無標示（必須修正） | 資料損毀、資安事件或服務中斷 | 扣分，觸發等級上限 |
| `Major` | SonarQube | 無標示（必須修正） | 特定情境下會出錯，或明顯降低品質 | 扣分 |
| `Minor` | SonarQube | 無標示（必須修正） | 能運作，但有更好的寫法 | 扣分 |
| `Nit` | Google | `Nit:` | 風格偏好，不影響核准 | 扣分（最低級） |
| — | Google | `Optional:`、`FYI:` | 建議或資訊 | 不列為嚴重度，以 `N` 記錄，不扣分 |

代碼與目前的四級相同，現有規則文件的檢查項不需要改嚴重度名稱。`defaults.ini` 的 `meaning` 依上表撰寫，並註明出處。

## 撰寫規則的工具

曾評估把撰寫規則相關的 Skill（code-review-scoring-standard）、腳本與模板移到 code-review-scoring-rules。

### 評估時的問題點

- **解析器是共用的**：`standard.{sh,zsh,ps1}` 的 `lint`、`stamp` 用於撰寫規則，但 `parse`、`resolve`、`plan` 與 lint 都是評分流程的一部分（步驟 1 分配規則、setup check 執行 lint）。解析器只能有一份，否則兩個專案的規則格式解讀會不一致。
- **相依方向**：目前只有評分專案依賴規則專案（`settings.ini` 的 `[rules] root`）。撰寫 Skill 移過去後若要呼叫評分專案的 lint，規則專案也要知道評分專案的位置，形成雙向相依。
- **版本相容**：兩個專案分開發版後，規則格式變更時必須同時更新兩邊；需要在規則專案記錄格式版本，由 setup check 檢查相容性。
- **Skill 安裝**：`link-skills` 目前只連結評分專案的 Skill，規則專案的 Skill 需要另外的安裝方式，或由評分專案的 `link-skills` 依 `[rules] root` 一併連結。
- **測試**：tests/standards 的測試資料與掃描規則檢查（awk 與 .NET 的正規表示式編譯）要跟著搬，評分專案的 tests/workflow 也需要一套規則專案的測試資料。
- **權限與審核**：規則專案原本只有規則內容，加入腳本後，修改規則的 PR 也可能動到解析器，審核時要分開看待。

### 決定：不搬移

評估後不搬移，所有操作（評分、檢查、產生與審核規則）都從評分專案起始。規則專案只放規則內容與設定（`rules.ini`、`defaults.ini`、各規則目錄），不放腳本與 Skill。

- 解析器、`lint`、`stamp` 與 code-review-scoring-standard Skill 都留在評分專案，相依維持單向（評分專案 → 規則專案）。
- code-review-scoring-standard Skill 改由 `settings.ini` 的 `[rules] root` 找到規則：
  - 檢查模式：lint `rules.ini`、`defaults.ini` 與所有已登錄的規則（含停用的）。
  - 產生、審核模式：以 `rules.ini` 的規則名稱指定目標，`stamp` 把掃描規則寫入該規則目錄中 `rule.ini` 的 `scan` 位置。
- `templates/<語言>/scoring-rule-template.md` 留在評分專案，更新為新格式，並新增 `rule.ini` 範本（含各區段說明）。
- 規則專案 README 說明規則的撰寫與檢查都從評分專案執行，並連結到評分專案的模板與說明文件。
