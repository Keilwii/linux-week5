"""MariaDB access. Settings come from the environment file /etc/viikko5/viikko5.env."""

import os

import pymysql
import pymysql.cursors

DatabaseError = pymysql.MySQLError


def connect():
    return pymysql.connect(
        unix_socket=os.environ.get("DB_SOCKET", "/run/mysqld/mysqld.sock"),
        user=os.environ.get("DB_USER", "viikko5"),
        password=os.environ.get("DB_PASSWORD", ""),
        database=os.environ.get("DB_NAME", "viikko5"),
        charset="utf8mb4",
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=True,
        connect_timeout=3,
    )


def save_message(session_id, role, content):
    with connect() as conn, conn.cursor() as cur:
        cur.execute(
            "INSERT INTO messages (session_id, role, content) VALUES (%s, %s, %s)",
            (session_id, role, content),
        )


def get_history(session_id, limit=10):
    """Last `limit` messages of a conversation, oldest first."""
    with connect() as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT role, content FROM (
                SELECT id, role, content FROM messages
                WHERE session_id = %s ORDER BY id DESC LIMIT %s
            ) AS last ORDER BY id
            """,
            (session_id, limit),
        )
        return list(cur.fetchall())
