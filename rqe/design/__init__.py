"""The design compiler: a sentence in, a whole game design out -- showing its work."""

from .compiler import (
    DEFAULTED,
    INFERRED,
    STATED,
    Analysis,
    Decision,
    DesignDocument,
    DesignError,
    analyse,
    compile_brief,
)

__all__ = [
    "DEFAULTED", "INFERRED", "STATED", "Analysis", "Decision",
    "DesignDocument", "DesignError", "analyse", "compile_brief",
]
