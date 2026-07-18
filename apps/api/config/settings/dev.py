"""Local development settings."""

from .base import *  # noqa: F401,F403
from .base import DEBUG  # noqa: F401

# DEBUG comes from the environment (DJANGO_DEBUG); default False even here so that
# forgetting to set it never silently exposes stack traces.
