"use client";
import { Fragment, jsx, jsxs } from "react/jsx-runtime";
import { useState, useEffect, useCallback, useTransition } from "react";
import { getPicklistStatus, printNextBatch, printSelectedOrders } from "../actions.js";
function PackageIcon({ size = 16 }) {
  return /* @__PURE__ */ jsxs("svg", { width: size, height: size, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeWidth: "2", strokeLinecap: "round", strokeLinejoin: "round", children: [
    /* @__PURE__ */ jsx("path", { d: "M16.5 9.4 7.55 4.24" }),
    /* @__PURE__ */ jsx("path", { d: "M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z" }),
    /* @__PURE__ */ jsx("polyline", { points: "3.29 7 12 12 20.71 7" }),
    /* @__PURE__ */ jsx("line", { x1: "12", x2: "12", y1: "22", y2: "12" })
  ] });
}
function PrinterIcon({ size = 16 }) {
  return /* @__PURE__ */ jsxs("svg", { width: size, height: size, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeWidth: "2", strokeLinecap: "round", strokeLinejoin: "round", children: [
    /* @__PURE__ */ jsx("polyline", { points: "6 9 6 2 18 2 18 9" }),
    /* @__PURE__ */ jsx("path", { d: "M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2" }),
    /* @__PURE__ */ jsx("rect", { width: "12", height: "8", x: "6", y: "14" })
  ] });
}
function RefreshIcon({ size = 16 }) {
  return /* @__PURE__ */ jsxs("svg", { width: size, height: size, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeWidth: "2", strokeLinecap: "round", strokeLinejoin: "round", children: [
    /* @__PURE__ */ jsx("path", { d: "M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8" }),
    /* @__PURE__ */ jsx("path", { d: "M21 3v5h-5" }),
    /* @__PURE__ */ jsx("path", { d: "M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16" }),
    /* @__PURE__ */ jsx("path", { d: "M8 16H3v5" })
  ] });
}
function ClockIcon({ size = 14 }) {
  return /* @__PURE__ */ jsxs("svg", { width: size, height: size, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeWidth: "2", strokeLinecap: "round", strokeLinejoin: "round", children: [
    /* @__PURE__ */ jsx("circle", { cx: "12", cy: "12", r: "10" }),
    /* @__PURE__ */ jsx("polyline", { points: "12 6 12 12 16 14" })
  ] });
}
function formatTime(epoch) {
  if (!epoch) return "\u2014";
  const d = new Date(epoch * 1e3);
  return d.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
}
function formatPlatform(p) {
  if (!p || p === "unknown") return "\u2014";
  return p.charAt(0).toUpperCase() + p.slice(1).replace(/_/g, " ");
}
function elapsedMinutes(epoch) {
  return Math.floor((Date.now() / 1e3 - epoch) / 60);
}
function TimerBanner({ timer, batchSize }) {
  if (!timer) return null;
  const elapsed = elapsedMinutes(timer.started_at);
  const remaining = Math.max(0, 60 - elapsed);
  const pct = Math.min(100, elapsed / 60 * 100);
  return /* @__PURE__ */ jsxs("div", { className: "rounded-lg border border-yellow-500/30 bg-yellow-500/5 p-4 mb-4", children: [
    /* @__PURE__ */ jsxs("div", { className: "flex items-center gap-2 mb-2", children: [
      /* @__PURE__ */ jsx(ClockIcon, { size: 14 }),
      /* @__PURE__ */ jsx("span", { className: "text-sm font-medium text-yellow-500", children: "Auto-batch timer running" })
    ] }),
    /* @__PURE__ */ jsxs("div", { className: "text-xs text-muted-foreground mb-2", children: [
      timer.order_count,
      " order",
      timer.order_count !== 1 ? "s" : "",
      " waiting \u2014 will auto-print in",
      " ",
      /* @__PURE__ */ jsxs("strong", { className: "text-foreground", children: [
        remaining,
        " min"
      ] }),
      " if ",
      batchSize,
      " not reached"
    ] }),
    /* @__PURE__ */ jsx("div", { className: "h-1.5 rounded-full bg-border overflow-hidden", children: /* @__PURE__ */ jsx(
      "div",
      {
        className: "h-full rounded-full bg-yellow-500 transition-all",
        style: { width: `${pct}%` }
      }
    ) })
  ] });
}
function QueueCard({ readyCount, printedCount, batchSize }) {
  const fillPct = Math.min(100, readyCount / batchSize * 100);
  return /* @__PURE__ */ jsxs("div", { className: "rounded-lg border bg-card p-4 mb-4", children: [
    /* @__PURE__ */ jsxs("div", { className: "flex items-center justify-between mb-3", children: [
      /* @__PURE__ */ jsxs("div", { children: [
        /* @__PURE__ */ jsxs("p", { className: "text-base font-medium", children: [
          readyCount,
          " orders ready to pick"
        ] }),
        /* @__PURE__ */ jsxs("p", { className: "text-xs text-muted-foreground mt-0.5", children: [
          printedCount,
          " already printed today"
        ] })
      ] }),
      /* @__PURE__ */ jsxs("div", { className: "text-right", children: [
        /* @__PURE__ */ jsx("p", { className: "text-xs text-muted-foreground", children: "Batch threshold" }),
        /* @__PURE__ */ jsxs("p", { className: "text-sm font-medium", children: [
          readyCount,
          " / ",
          batchSize
        ] })
      ] })
    ] }),
    /* @__PURE__ */ jsx("div", { className: "h-2 rounded-full bg-border overflow-hidden", children: /* @__PURE__ */ jsx(
      "div",
      {
        className: "h-full rounded-full bg-green-500 transition-all",
        style: { width: `${fillPct}%` }
      }
    ) })
  ] });
}
function OrderRow({ order, selected, onToggle }) {
  return /* @__PURE__ */ jsxs("label", { className: "flex items-center gap-3 p-3 rounded-md hover:bg-accent/50 cursor-pointer", children: [
    /* @__PURE__ */ jsx(
      "input",
      {
        type: "checkbox",
        checked: selected,
        onChange: () => onToggle(order.order_id),
        className: "shrink-0"
      }
    ),
    /* @__PURE__ */ jsxs("div", { className: "flex-1 min-w-0", children: [
      /* @__PURE__ */ jsxs("div", { className: "flex items-center gap-2", children: [
        /* @__PURE__ */ jsxs("span", { className: "font-mono text-sm font-medium", children: [
          "#",
          order.order_id
        ] }),
        /* @__PURE__ */ jsx("span", { className: "text-[10px] bg-muted text-muted-foreground px-1.5 py-0.5 rounded", children: formatPlatform(order.platform) })
      ] }),
      /* @__PURE__ */ jsx("p", { className: "text-xs text-muted-foreground truncate mt-0.5", children: order.customer })
    ] }),
    /* @__PURE__ */ jsxs("div", { className: "text-right shrink-0", children: [
      /* @__PURE__ */ jsx("p", { className: "text-xs text-muted-foreground", children: formatTime(order.date_add) }),
      /* @__PURE__ */ jsxs("p", { className: "text-xs text-muted-foreground", children: [
        order.product_count,
        " SKU",
        order.product_count !== 1 ? "s" : ""
      ] })
    ] })
  ] });
}
function RecentBatches({ batches }) {
  if (!batches.length) return null;
  return /* @__PURE__ */ jsxs("div", { className: "mt-6", children: [
    /* @__PURE__ */ jsx("p", { className: "text-xs font-medium text-muted-foreground uppercase tracking-wide mb-2", children: "Recent picklists" }),
    /* @__PURE__ */ jsx("div", { className: "flex flex-col gap-1", children: batches.map((id) => /* @__PURE__ */ jsxs(
      "a",
      {
        href: `/picklist/print/${id}`,
        target: "_blank",
        rel: "noreferrer",
        className: "flex items-center gap-2 text-xs text-muted-foreground hover:text-foreground px-2 py-1.5 rounded hover:bg-accent/50 transition-colors",
        children: [
          /* @__PURE__ */ jsx(PrinterIcon, { size: 12 }),
          /* @__PURE__ */ jsx("span", { className: "font-mono", children: id })
        ]
      },
      id
    )) })
  ] });
}
function PicklistPage() {
  const [status, setStatus] = useState(null);
  const [loading, setLoading] = useState(true);
  const [selectedIds, setSelectedIds] = useState(/* @__PURE__ */ new Set());
  const [isPrinting, startPrint] = useTransition();
  const [feedback, setFeedback] = useState(null);
  const load = useCallback(async () => {
    try {
      const data = await getPicklistStatus();
      setStatus(data);
    } catch (e) {
      console.error("Failed to load picklist status", e);
    } finally {
      setLoading(false);
    }
  }, []);
  useEffect(() => {
    load();
    const interval = setInterval(load, 6e4);
    return () => clearInterval(interval);
  }, [load]);
  function toggleOrder(orderId) {
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (next.has(orderId)) next.delete(orderId);
      else next.add(orderId);
      return next;
    });
  }
  function toggleAll() {
    if (!status) return;
    const allIds = status.orders.map((o) => o.order_id);
    if (selectedIds.size === allIds.length) {
      setSelectedIds(/* @__PURE__ */ new Set());
    } else {
      setSelectedIds(new Set(allIds));
    }
  }
  function openPrint(batchId) {
    window.open(`/picklist/print/${batchId}?autoprint=1`, "_blank");
    setFeedback({ ok: true, msg: "Picklist opened in new tab" });
    setTimeout(() => setFeedback(null), 4e3);
    load();
  }
  function handlePrintNext() {
    startPrint(async () => {
      setFeedback(null);
      const result = await printNextBatch(status?.batch_size);
      if (result.error) {
        setFeedback({ ok: false, msg: result.error });
      } else {
        openPrint(result.batch_id);
      }
    });
  }
  function handlePrintSelected() {
    if (selectedIds.size === 0) return;
    startPrint(async () => {
      setFeedback(null);
      const result = await printSelectedOrders([...selectedIds]);
      if (result.error) {
        setFeedback({ ok: false, msg: result.error });
      } else {
        openPrint(result.batch_id);
      }
    });
  }
  const allSelected = status && selectedIds.size === status.orders.length && status.orders.length > 0;
  const busy = isPrinting;
  return /* @__PURE__ */ jsxs(Fragment, { children: [
    /* @__PURE__ */ jsxs("div", { className: "flex items-center justify-between mb-4", children: [
      /* @__PURE__ */ jsx("div", {}),
      /* @__PURE__ */ jsxs(
        "button",
        {
          onClick: load,
          className: "flex items-center gap-1.5 px-2.5 py-1.5 text-xs border border-border text-muted-foreground hover:text-foreground hover:bg-accent rounded-md transition-colors",
          disabled: loading,
          children: [
            /* @__PURE__ */ jsx(RefreshIcon, { size: 12 }),
            "Refresh"
          ]
        }
      )
    ] }),
    loading ? /* @__PURE__ */ jsxs("div", { className: "space-y-3", children: [
      /* @__PURE__ */ jsx("div", { className: "h-24 animate-pulse rounded-lg bg-border/50" }),
      /* @__PURE__ */ jsx("div", { className: "h-16 animate-pulse rounded-lg bg-border/50" })
    ] }) : !status ? /* @__PURE__ */ jsx("p", { className: "text-sm text-muted-foreground", children: "Failed to load picklist status." }) : /* @__PURE__ */ jsxs(Fragment, { children: [
      /* @__PURE__ */ jsx(TimerBanner, { timer: status.timer, batchSize: status.batch_size }),
      /* @__PURE__ */ jsx(
        QueueCard,
        {
          readyCount: status.ready_count,
          printedCount: status.printed_count,
          batchSize: status.batch_size
        }
      ),
      /* @__PURE__ */ jsxs("div", { className: "flex gap-2 mb-4 flex-wrap", children: [
        /* @__PURE__ */ jsxs(
          "button",
          {
            onClick: handlePrintNext,
            disabled: busy || status.ready_count === 0,
            className: "flex items-center gap-1.5 px-3 py-1.5 text-sm bg-foreground text-background rounded-md hover:bg-foreground/90 disabled:opacity-50 transition-colors",
            children: [
              /* @__PURE__ */ jsx(PrinterIcon, { size: 14 }),
              busy ? "Generating\u2026" : `Print next ${status.batch_size}`
            ]
          }
        ),
        /* @__PURE__ */ jsxs(
          "button",
          {
            onClick: handlePrintSelected,
            disabled: busy || selectedIds.size === 0,
            className: "flex items-center gap-1.5 px-3 py-1.5 text-sm border border-border text-muted-foreground hover:bg-accent hover:text-foreground disabled:opacity-50 rounded-md transition-colors",
            children: [
              /* @__PURE__ */ jsx(PrinterIcon, { size: 14 }),
              busy ? "Generating\u2026" : `Print selected (${selectedIds.size})`
            ]
          }
        )
      ] }),
      feedback && /* @__PURE__ */ jsx(
        "div",
        {
          className: `rounded-md px-3 py-2 text-xs mb-4 ${feedback.ok ? "bg-green-500/10 text-green-500 border border-green-500/30" : "bg-destructive/10 text-destructive border border-destructive/30"}`,
          children: feedback.msg
        }
      ),
      status.orders.length > 0 ? /* @__PURE__ */ jsxs("div", { className: "rounded-lg border bg-card", children: [
        /* @__PURE__ */ jsx("div", { className: "flex items-center justify-between px-3 py-2 border-b", children: /* @__PURE__ */ jsxs("label", { className: "flex items-center gap-2 text-xs text-muted-foreground cursor-pointer", children: [
          /* @__PURE__ */ jsx(
            "input",
            {
              type: "checkbox",
              checked: allSelected,
              onChange: toggleAll
            }
          ),
          allSelected ? "Deselect all" : `Select all (${status.orders.length})`
        ] }) }),
        /* @__PURE__ */ jsx("div", { className: "divide-y", children: status.orders.map((order) => /* @__PURE__ */ jsx(
          OrderRow,
          {
            order,
            selected: selectedIds.has(order.order_id),
            onToggle: toggleOrder
          },
          order.order_id
        )) })
      ] }) : /* @__PURE__ */ jsxs("div", { className: "rounded-lg border border-dashed p-8 text-center", children: [
        /* @__PURE__ */ jsx("div", { className: "flex justify-center mb-3", children: /* @__PURE__ */ jsx(PackageIcon, { size: 24 }) }),
        /* @__PURE__ */ jsx("p", { className: "text-sm font-medium mb-1", children: "No orders ready to pick" }),
        /* @__PURE__ */ jsx("p", { className: "text-xs text-muted-foreground", children: 'Orders will appear here when they reach "ready to pick" status in BaseLinker.' })
      ] }),
      /* @__PURE__ */ jsx(RecentBatches, { batches: status.recent_batches })
    ] })
  ] });
}
export {
  PicklistPage
};
