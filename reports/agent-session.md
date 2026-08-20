# Game Agent Bridge Session

Mode: **blackbox**
Started: **True**

## Action evidence

| # | Result | Action | Reason |
|---:|---|---|---|
| 1 | PASS | `{'type': 'walk_to', 'target': 'BasicPackStore', 'timeout': 8, 'controller': 'human'}` |  |
| 2 | PASS | `{'type': 'interact', 'target': 'PurchasePrompt'}` |  |
| 3 | FAIL | `{'type': 'interact', 'target': 'PurchasePrompt'}` | already_purchased_or_insufficient_funds |
