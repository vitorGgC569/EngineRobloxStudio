# CLI surface

The source-checkout CLI is `python rqe.py`. A packaged install exposes the same commands as `rqe` through the `pyproject.toml` entry point.

Supported commands:

- `rqe audit <project>`: run the full evidence suite and write reports;
- `rqe verify <project>`: run the suite and fail when release is blocked;
- `rqe fix <project>`: run the suite and write a fix plan.

