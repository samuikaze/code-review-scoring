# 設定檔說明

<!-- markdownlint-disable MD028 -->
<!-- markdownlint-disable MD033 -->

[English](../en/configurations.md) | 繁體中文

- [設定檔一覽](#設定檔一覽)
- [settings.ini](#settingsini)
- [plugins.ini](#pluginsini)

## 設定檔一覽

`configs/` 下的設定檔都不進版控，版控中只有範本 `configs/*.example.ini`。
範本只放可取消註解的區段範例，各區段與鍵的說明都在本文件。

| 設定檔 | 範本 | 內容 |
| --- | --- | --- |
| `configs/settings.ini` | `configs/settings.example.ini` | 執行方式、各平台 Sub-Agent 使用的 model 與 reasoning、報告語言、評分規則專案位置 |
| `configs/plugins.ini` | `configs/plugins.example.ini` | 外掛 Skill 清單 |

設定檔一律為 INI 格式，值以雙引號包住，`;` 或 `#` 開頭的行是註解。
相對路徑一律以設定檔所在目錄（`configs/`）為準。

## settings.ini

不需要手動建立：第一次執行完整流程時，設定檢查會引導建立 `configs/settings.ini`。
若要預先設定，請在專案根目錄複製範本後，取消註解要使用的區段並修改：

```bash
cp configs/settings.example.ini configs/settings.ini
```

### workflow 區段

必要。

| 鍵 | 說明 |
| --- | --- |
| `subagent` | `"true"`：每一步派發一個 Sub-Agent 執行；`"false"`：只由主 Agent 逐步執行。平台不支援 Sub-Agent 時，即使設為 `"true"` 也由主 Agent 逐步執行。 |

```ini
[workflow]
subagent="true"
```

### 平台區段

只有 `subagent` 為 `"true"` 時需要。區段名稱為平台名稱，例如 `Claude`、`Copilot`、`Codex`、`Gemini`；
`workflow`、`language` 與 `rules` 為保留名稱，不能當作平台名稱。

| 鍵 | 說明 |
| --- | --- |
| `model` | Sub-Agent 使用的 model，須為該平台 Sub-Agent 工具接受的值。 |
| `reasoning` | Sub-Agent 的 reasoning 等級。GitHub Copilot 目前不會套用，見[注意事項](notices.md#github-copilot-的適用性)。 |

```ini
[Claude]
model="sonnet 5.5"
reasoning="high"

[Codex]
model="gpt-5.6"
reasoning="xhigh"
```

### language 區段

可省略。

| 鍵 | 說明 |
| --- | --- |
| `report` | 報告使用的語言，即專案根目錄 `templates/` 下的語言資料夾名稱，例如 `zh-tw`、`en`；預設 `zh-tw`。決定報告模板（`report-template.md`、`labels.tsv`），以及步驟 2、3 撰寫說明文字的語言。 |

`templates/` 下只有一種語言的報告模板時（不論是否放在語言資料夾中），忽略此設定，直接使用該模板。

```ini
[language]
report="zh-tw"
```

### rules 區段

必要。

| 鍵 | 說明 |
| --- | --- |
| `root` | 評分規則專案（例如 code-review-scoring-rules）的根目錄，完整路徑或相對於 `configs/` 的路徑。Windows 請使用斜線，例如 `C:/Users/me/Documents/code-review-scoring-rules`。 |

規則專案根目錄有 `rules.ini`（登錄與啟用規則）、`defaults.ini`（預設的面向配分、嚴重度分級與等級），
以及每套規則一個目錄（`rule.ini`、評分規則文件與掃描規則）；
`rule.ini` 的寫法見 [`templates/zh-tw/rule-template.ini`](../../templates/zh-tw/rule-template.ini)。

```ini
[rules]
root="../../code-review-scoring-rules"
```

## plugins.ini

外掛 Skill 清單。建立 `configs/plugins.ini` 的方式：

- 執行評分時由設定檢查引導建立，或執行 `skills/code-review-scoring/scripts/setup.*` 的 `wizard` 逐步建立。
- 在專案根目錄複製範本後自行修改：

  ```bash
  cp configs/plugins.example.ini configs/plugins.ini
  ```

沒有 `configs/plugins.ini` 時，評分流程會先要求建立；不使用外掛時，
也要建立一份沒有外掛的 `plugins.ini`（`setup plugins --none`）。

執行 `scripts/link-skills.*` 時，會把這裡列出的 Skill 與 `skills/` 下的 Skill
一起連結到 `.agents/skills` 等目錄；從清單移除的外掛，下次同步時會一併解除連結。
評分流程的步驟 2（CR）會依 PR 異動的檔案與 `applies`，決定要執行哪些外掛。

每個外掛一個區段，區段名稱必須和該 Skill 的 `SKILL.md` 中的 `name` 一致。

| 鍵 | 說明 |
| --- | --- |
| `path` | Skill 資料夾路徑，必填。相對路徑以 `configs/` 為準。 |
| `applies` | 適用的檔案範圍，以逗號分隔的萬用字元；選填，未填表示全部異動檔案。 |
| `mode` | `mapped`：CR 意見在分析程式碼時確認，確認屬實的一律扣分，不成立的需說明原因（預設）；`advisory`：CR 意見只呈現在報告中，不影響分數。 |

```ini
[backend-code-review]
path="../../shared-skills/backend-code-review"
applies="*.java,*.kt,*.sql"
mode="mapped"

[frontend-code-review]
path="../../shared-skills/frontend-code-review"
applies="*.ts,*.tsx,*.vue,*.scss"
mode="advisory"
```
