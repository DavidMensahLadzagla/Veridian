"""Root URL configuration. All API routes live under /api/v1/."""

from django.urls import include, path

urlpatterns = [
    path("api/v1/", include("core.urls")),
]
