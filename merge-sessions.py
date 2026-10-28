# 会话归属统一 (v3.4 会话互通)
# 用法: python merge-sessions.py <workbuddy.db 路径> <目标账号 uid>
# 作用: 把会话库中属于其他账号的会话, 归属改到目标账号, 使其在界面上可见/连续
import sqlite3
import sys


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: merge-sessions.py <db> <uid>")
        return 2
    db, uid = sys.argv[1], sys.argv[2]
    con = sqlite3.connect(db, timeout=10)
    try:
        before = con.execute(
            "SELECT user_id, count(*) FROM sessions GROUP BY user_id"
        ).fetchall()
        cur = con.execute(
            "UPDATE sessions SET user_id = ? WHERE user_id IS NOT NULL AND user_id <> ?",
            (uid, uid),
        )
        con.commit()
        total = con.execute("SELECT count(*) FROM sessions WHERE user_id = ?", (uid,)).fetchone()[0]
        print("moved={} total_for_target={} before={}".format(cur.rowcount, total, before))
        return 0
    finally:
        con.close()


if __name__ == "__main__":
    sys.exit(main())
