"""Health check. Public, unauthenticated. Used by Railway and the Flutter ConnectivityMonitor."""

from __future__ import annotations

from django.core.cache import cache
from django.db import connections
from django.db.utils import OperationalError
from rest_framework.permissions import AllowAny
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework.views import APIView


class HealthView(APIView):
    authentication_classes: list = []
    permission_classes = [AllowAny]

    def get(self, request: Request) -> Response:
        db_ok = self._check_db()
        redis_ok = self._check_redis()
        healthy = db_ok and redis_ok
        return Response(
            {
                "status": "healthy" if healthy else "unhealthy",
                "db": "ok" if db_ok else "error",
                "redis": "ok" if redis_ok else "error",
            },
            status=200 if healthy else 503,
        )

    @staticmethod
    def _check_db() -> bool:
        try:
            with connections["default"].cursor() as cursor:
                cursor.execute("SELECT 1")
                cursor.fetchone()
            return True
        except OperationalError:
            return False

    @staticmethod
    def _check_redis() -> bool:
        try:
            cache.set("healthcheck", "1", timeout=5)
            return cache.get("healthcheck") == "1"
        except Exception:  # noqa: BLE001 — health probe must never raise
            return False
