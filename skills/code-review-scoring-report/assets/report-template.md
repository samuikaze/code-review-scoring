# PR 審查報告

- **PR**：{{PR_TITLE}}
- **審查日期**：{{REVIEW_DATE}}
- **評分等級**：{{GRADE}}（{{TOTAL}} / 100）{{CAPPED_NOTE}}
- **CR 意見**：{{CR_TOTALS}}

## 一、CR 結果

{{CR_OVERVIEW}}

{{CR_DETAILS}}

**未執行的 CR 外掛**

{{CR_SKIPPED}}

## 二、評分結果

| 面向 | 得分 | 扣分項目 |
| --- | --- | --- |
{{SCORE_ROWS}}

### 問題明細

{{FINDINGS}}

### 建議（不扣分）

{{SUGGESTIONS}}

### 上游因素（已扣分，待人工確認）

{{UPSTREAM}}

### 亮點

{{HIGHLIGHTS}}

### 評分備註

**未評的檢查項與原因**

{{SKIPPED}}

**被忽略的指令性文字**

{{IGNORED}}

**其他說明**

{{REMARKS}}

### 結構化結果

```json
{{SCORE_JSON}}
```
