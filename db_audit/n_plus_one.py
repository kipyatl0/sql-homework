"""N+1 in SQLAlchemy: loading orders and touching order.items in a loop.

Run (the database from compose.yaml must be up):
    uv run python db_audit/n_plus_one.py

Every scenario runs in its own session, so the identity map of one scenario
does not hide queries of another. The SQL log (echo=True) shows each statement,
and the summary at the end shows how many of them every scenario sent.

SQL_ECHO=false turns the SQL log off and leaves only the summary.
"""

import os
import time
from collections.abc import Callable, Iterator, Sequence
from contextlib import contextmanager
from datetime import datetime
from decimal import Decimal

from sqlalchemy import ForeignKey, Numeric, String, create_engine, event, select
from sqlalchemy.orm import (
    DeclarativeBase,
    Mapped,
    Session,
    joinedload,
    mapped_column,
    relationship,
    selectinload,
)

# 127.0.0.1, not localhost: compose publishes the port on IPv4 only, and on Windows "localhost"
# resolves to ::1 first, so every connect hangs on IPv6 before falling back to IPv4.
DATABASE_URL = os.getenv(
    "DATABASE_URL", "postgresql+psycopg://app:app@127.0.0.1:5433/shop"
)
SQL_ECHO = os.getenv("SQL_ECHO", "true").lower() == "true"

# How many orders one "page" loads. With lazy loading it costs 1 + ORDERS_LIMIT queries.
ORDERS_LIMIT = 200

engine = create_engine(DATABASE_URL, echo=SQL_ECHO)


class Base(DeclarativeBase):
    pass


class Order(Base):
    __tablename__ = "orders"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int]
    status: Mapped[str] = mapped_column(String(20))
    total_amount: Mapped[Decimal] = mapped_column(Numeric(10, 2))
    created_at: Mapped[datetime]
    updated_at: Mapped[datetime]

    # Default strategy lazy="select": items are loaded by a separate SELECT on first access.
    items: Mapped[list["OrderItem"]] = relationship(back_populates="order")


class OrderItem(Base):
    __tablename__ = "order_items"

    id: Mapped[int] = mapped_column(primary_key=True)
    order_id: Mapped[int] = mapped_column(ForeignKey("orders.id"))
    product_id: Mapped[int]
    quantity: Mapped[int]
    price: Mapped[Decimal] = mapped_column(Numeric(10, 2))

    order: Mapped[Order] = relationship(back_populates="items")


@contextmanager
def count_queries() -> Iterator[list[str]]:
    """Collects every statement the engine sends to the database while the block runs."""
    statements: list[str] = []

    def on_execute(conn, cursor, statement, parameters, context, executemany):
        statements.append(statement)

    event.listen(engine, "before_cursor_execute", on_execute)
    try:
        yield statements
    finally:
        event.remove(engine, "before_cursor_execute", on_execute)


def recent_orders_query():
    """The latest completed orders: one "page" of an order history screen."""
    return (
        select(Order)
        .where(Order.status == "completed")
        .order_by(Order.created_at.desc())
        .limit(ORDERS_LIMIT)
    )


def load_orders_lazy(session: Session) -> Sequence[Order]:
    """N+1: one query for the orders, then one more for the items of every order."""
    return session.scalars(recent_orders_query()).all()


def load_orders_joinedload(session: Session) -> Sequence[Order]:
    """Fix #1: orders and their items in a single query via LEFT OUTER JOIN."""
    # TODO: add the joinedload loader option to recent_orders_query().
    # Предпочтительный вариант, т.к. у нас one-to-many связь между order и order_items
    return (
        session.scalars(recent_orders_query().options(joinedload(Order.items)))
        .unique()
        .all()
    )


def load_orders_selectinload(session: Session) -> Sequence[Order]:
    """Fix #2: one query for the orders plus one query for the items of all of them (WHERE order_id IN ...)."""
    # TODO: add the selectinload loader option to recent_orders_query().
    # Ну можно и так
    return session.scalars(
        recent_orders_query().options(selectinload(Order.items))
    ).all()


def render_orders(orders: Sequence[Order]) -> list[str]:
    """What an API endpoint or a template does: walks the orders and reads their items."""
    lines = []
    for order in orders:
        # order.items is the place where the lazy load fires.
        items_count = sum(item.quantity for item in order.items)
        lines.append(
            f"order #{order.id}: {len(order.items)} lines, {items_count} pcs, {order.total_amount}"
        )
    return lines


Loader = Callable[[Session], Sequence[Order]]

SCENARIOS: list[tuple[str, Loader]] = [
    ("lazy (N+1)", load_orders_lazy),
    ("joinedload", load_orders_joinedload),
    ("selectinload", load_orders_selectinload),
]


def run_scenario(name: str, loader: Loader) -> tuple[int, float] | None:
    print(f"\n{'=' * 20} {name} {'=' * 20}")
    with Session(engine) as session, count_queries() as statements:
        started = time.perf_counter()
        try:
            orders = loader(session)
        except NotImplementedError:
            print("not implemented yet, skipped")
            return None
        lines = render_orders(orders)
        elapsed_ms = (time.perf_counter() - started) * 1000

    print(*lines[:3], "...", sep="\n")
    print(f"--> {name}: {len(statements)} SQL queries, {elapsed_ms:.1f} ms")
    return len(statements), elapsed_ms


def main() -> None:
    # Open a connection up front, so the first scenario does not pay for the connect.
    with engine.connect():
        pass

    results = {name: run_scenario(name, loader) for name, loader in SCENARIOS}

    print(f"\n{'scenario':<15}{'queries':>10}{'time, ms':>12}")
    for name, result in results.items():
        if result is None:
            print(f"{name:<15}{'-':>10}{'-':>12}")
        else:
            queries, elapsed_ms = result
            print(f"{name:<15}{queries:>10}{elapsed_ms:>12.1f}")


if __name__ == "__main__":
    main()
