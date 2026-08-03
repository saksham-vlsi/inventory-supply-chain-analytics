# Business Problem

## Context

A retailer selling 4,876 SKUs into 43 countries, buying from 73 vendors. Two years of real transactions,
two years of real purchase orders.

The recurring failure in inventory management is not shortage *or* excess — it is both, simultaneously,
in the same warehouse. This dataset shows exactly that: **1,470 SKUs at stock-out risk while 2,163 SKUs
sit in dead or overstocked positions holding £1.10 M of capital.**

## The questions this project has to answer

1. **Which SKUs actually matter?** Not by gut feel — by revenue concentration and by how predictable
   their demand is.
2. **How much of each should we hold?** Safety stock and reorder point, derived rather than guessed.
3. **Where is capital trapped?** Which SKUs are holding stock against demand that has already gone.
4. **Which suppliers can we plan around?** Not just who hits their date, but whose lead time is
   *consistent* enough to build a plan on.
5. **What is coming back?** Return rate by category, from real credit notes.

## Why the design splits value from predictability

The central analytical decision is segmenting on **two** axes rather than one.

Classic ABC ranks SKUs by revenue and tells you to "manage class A closely". That is where most inventory
analysis stops, and it hides the actual problem. Adding XYZ — the coefficient of variation of weekly
demand — splits class A into three very different management problems:

| | Meaning | Policy |
|---|---|---|
| **AX** (49 SKUs) | High value, stable | Tight reorder points, low buffer, automate |
| **AY** (422 SKUs) | High value, variable | Standard safety stock, monitor |
| **AZ** (562 SKUs) | High value, erratic | Forecasting effort, demand shaping, high buffer |

AZ carries £6.46 M of revenue at a demand CV of 2.46 and absorbs £964,785 of planned inventory. Under a
single-axis ABC it is invisible — it just looks like "class A".

## Why lead time is measured, not assumed

Safety stock scales with `√lead time`, so the lead-time input drives the entire inventory plan. Assuming
a round number silently determines the answer.

This project instead takes the **median observed vendor lead time (91 days)** from 4,592 real purchase
orders and uses that as the planning input. It is the one deliberate connection between the demand feed
and the procurement feed, and it is documented as such.

## Success criteria

| Criterion | Met |
|---|---|
| Demand cleaned before any statistic is computed | 5 line types classified; 11,834 non-demand lines excluded and reported |
| Every planning input declared and overridable | `planning_assumptions`, 5 inputs, one place |
| Metrics that depend on unmeasured stock are labelled as modelled | `implied_*` / `avg_inventory_*` prefixes throughout |
| Supplier ranking robust to missing data | `score_basis` column; RDC channel scored on adherence only |
| Relational implementation, not just a script | 5 tables with PK/FK/CHECK constraints, 18 queries |

## Scope boundary

Outbound delivery performance — on-time delivery, lead-time decomposition, carrier attribution — is out
of scope here and is covered in the companion project,
*[Warehouse Operations KPI Dashboard](https://github.com/saksham-vlsi/warehouse-operations-kpi-dashboard)*,
on a dataset carrying full order-lifecycle timestamps.
