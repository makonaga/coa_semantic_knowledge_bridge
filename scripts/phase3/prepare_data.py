"""Phase 3 用データ生成。

datasets/change-point-management/change_points.json から以下を生成する:
  build/phase3/glue/change_points/change_points.csv  — Glue テーブル用(英語ヘッダ)
  build/phase3/glue/models/models.csv                — 機種マスタ(FK 推論の相手先)
  build/phase3/documents/CP-XXX_<機種名>.md          — Tier 3 用文書 100 件

カラム名は Glue/Athena の制約(日本語カラム名は不可)に合わせて英語とし、
日本語の意味はテーブル定義(scripts/phase3/glue/*.json)のカラムコメントに持たせる。
実行: リポジトリルートで python3 scripts/phase3/prepare_data.py
"""

import csv
import json
import pathlib

REPO = pathlib.Path(__file__).resolve().parents[2]
SRC = REPO / "datasets/change-point-management/change_points.json"
OUT = REPO / "build/phase3"

FIELD_MAP = [
    ("id", "id"),
    ("機種名", "model_name"),
    ("変更日", "change_date"),
    ("変更内容", "change_summary"),
    ("変更内容詳細", "change_detail"),
    ("評価内容", "evaluation_summary"),
    ("評価内容詳細", "evaluation_detail"),
    ("評価結果", "evaluation_result"),
]

# 機種マスタ(FK 推論のターゲット: change_points.model_name → models.model_name)
MODELS = [
    ("NE-UBS10A", "ビストロ", "スチームオーブンレンジ", "2022"),
    ("NE-BS9A", "ビストロ", "スチームオーブンレンジ", "2022"),
    ("NE-BS8A", "ビストロ", "スチームオーブンレンジ", "2022"),
    ("NE-BS6A", "ビストロ", "スチームオーブンレンジ", "2022"),
    ("NE-UBS5A", "ビストロ", "スチームオーブンレンジ", "2022"),
    ("NE-MS4A", "エレック", "オーブンレンジ", "2022"),
    ("NE-MS267", "エレック", "オーブンレンジ", "2021"),
    ("NE-FS3A", "", "単機能レンジ", "2022"),
    ("NE-FL1A", "", "単機能レンジ", "2021"),
    ("NE-FL222", "", "単機能レンジ", "2021"),
]

DOC_TEMPLATE = """# 変化点管理票 {id}

- 管理番号: {id}
- 機種名: {model}
- 変更日: {date}
- 評価結果: {result}

## 変更内容

{change_summary}

### 変更内容詳細

{change_detail}

## 評価内容

{eval_summary}

### 評価内容詳細

{eval_detail}
"""


def main() -> None:
    data = json.loads(SRC.read_text(encoding="utf-8"))
    assert len(data) == 100, f"expected 100 records, got {len(data)}"

    # 1) change_points.csv(英語ヘッダ)
    cp_dir = OUT / "glue/change_points"
    cp_dir.mkdir(parents=True, exist_ok=True)
    with open(cp_dir / "change_points.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, quoting=csv.QUOTE_ALL)
        w.writerow([en for _, en in FIELD_MAP])
        for r in data:
            w.writerow([r[ja] for ja, _ in FIELD_MAP])

    # 2) models.csv(機種マスタ)
    m_dir = OUT / "glue/models"
    m_dir.mkdir(parents=True, exist_ok=True)
    with open(m_dir / "models.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, quoting=csv.QUOTE_ALL)
        w.writerow(["model_name", "series_name", "product_category", "launch_year"])
        w.writerows(MODELS)

    # 3) Markdown 文書(1レコード=1文書)
    doc_dir = OUT / "documents"
    doc_dir.mkdir(parents=True, exist_ok=True)
    for r in data:
        body = DOC_TEMPLATE.format(
            id=r["id"],
            model=r["機種名"],
            date=r["変更日"],
            result=r["評価結果"],
            change_summary=r["変更内容"],
            change_detail=r["変更内容詳細"],
            eval_summary=r["評価内容"],
            eval_detail=r["評価内容詳細"],
        )
        (doc_dir / f"{r['id']}_{r['機種名']}.md").write_text(body, encoding="utf-8")

    print(f"OK: change_points.csv (100 rows), models.csv ({len(MODELS)} rows), "
          f"documents {len(list(doc_dir.glob('*.md')))} files -> {OUT}")


if __name__ == "__main__":
    main()
