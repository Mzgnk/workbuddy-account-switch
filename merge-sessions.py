# 会话归属统一 (v3.5 会话互通)
# 用法: python merge-sessions.py <workbuddy.db 路径> <目标账号 uid> [--check] [--json]
#   作用    : 把会话库中属于其他账号的会话, 归属改到目标账号, 使其在界面上可见/连续
#   --check : 只统计不改动(安全预览), 用来判断"归属是否一致"
#   --json  : 输出一行 JSON, 供插件/GUI 解析条数
import json
import sqlite3
import sys


def stats(con):
    rows = con.execute("SELECT user_id, count(*) FROM sessions GROUP BY user_id").fetchall()
    return {("" if k is None else k): v for k, v in rows}


def main() -> int:
    argv = [a for a in sys.argv[1:] if not a.startswith("--")]
    check = "--check" in sys.argv
    as_json = "--json" in sys.argv
    if len(argv) < 2:
        print("usage: merge-sessions.py <db> <uid> [--check] [--json]")
        return 2
    db, uid = argv[0], argv[1]

    try:
        con = sqlite3.connect(db, timeout=10)
    except sqlite3.Error as e:
        out = {"ok": False, "reason": "open-failed: {}".format(e)}
        print(json.dumps(out, ensure_ascii=False) if as_json else out["reason"])
        return 1

    try:
        before = stats(con)
        if check:
            moved = sum(v for k, v in before.items() if k != uid)
            total = before.get(uid, 0) + moved
        else:
            cur = con.execute(
                "UPDATE sessions SET user_id = ? "
                "WHERE user_id IS NULL OR user_id <> ?",
                (uid, uid),
            )
            moved = cur.rowcount
            con.commit()
            total = con.execute(
                "SELECT count(*) FROM sessions WHERE user_id = ?", (uid,)
            ).fetchone()[0]
        out = {
            "ok": True,
            "check": check,
            "uid": uid,
            "moved": moved,
            "total": total,
            "before": before,
        }
        if as_json:
            print(json.dumps(out, ensure_ascii=False))
        else:
            print("moved={} total_for_target={} before={}".format(moved, total, before))
        return 0
    except sqlite3.Error as e:
        out = {"ok": False, "reason": "sql-failed: {}".format(e)}
        print(json.dumps(out, ensure_ascii=False) if as_json else out["reason"])
        return 1
    finally:
        con.close()


if __name__ == "__main__":
    sys.exit(main())
