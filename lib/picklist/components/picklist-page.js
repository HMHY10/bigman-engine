"use client";
import { Fragment, jsx, jsxs } from "react/jsx-runtime";
import { useState, useEffect, useCallback } from "react";
import { PageLayout } from "../../chat/components/page-layout.js";
import {
  getWarehouseSummary,
  getPicklistDetail,
  printNextN,
  printSelected,
  runOvernightBatchAction,
  markPicklistPrinted,
  completePicklist,
  cancelOrder,
  createManualOrder
} from "../actions.js";
function StatusPill({ status }) {
  const map = {
    pending: "bg-yellow-500/10 text-yellow-500",
    batched: "bg-blue-500/10 text-blue-500",
    picked: "bg-green-500/10 text-green-500",
    shipped: "bg-green-500/10 text-green-500",
    cancelled: "bg-border/50 text-muted-foreground",
    printing: "bg-blue-500/10 text-blue-500",
    printed: "bg-blue-500/10 text-blue-500",
    completed: "bg-green-500/10 text-green-500"
  };
  return /* @__PURE__ */ jsx("span", { className: `inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ${map[status] || "bg-border/50 text-muted-foreground"}`, children: status });
}
function PicklistModal({ picklistId, onClose, onComplete }) {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [completing, setCompleting] = useState(false);
  useEffect(() => {
    getPicklistDetail(picklistId).then((d) => {
      setData(d);
      setLoading(false);
    });
  }, [picklistId]);
  const handlePrint = () => {
    window.open(`/warehouse/picklists/${picklistId}/print`, "_blank");
    markPicklistPrinted(picklistId).catch(() => {
    });
  };
  const handleComplete = async () => {
    setCompleting(true);
    await completePicklist(picklistId);
    setCompleting(false);
    onComplete?.();
    onClose();
  };
  return /* @__PURE__ */ jsx("div", { className: "fixed inset-0 z-50 flex items-center justify-center bg-black/50", onClick: onClose, children: /* @__PURE__ */ jsxs(
    "div",
    {
      className: "relative bg-card border border-border rounded-lg max-w-2xl w-full mx-4 max-h-[80vh] overflow-y-auto p-6",
      onClick: (e) => e.stopPropagation(),
      children: [
        /* @__PURE__ */ jsx(
          "button",
          {
            onClick: onClose,
            className: "absolute top-4 right-4 text-muted-foreground hover:text-foreground transition-colors",
            "aria-label": "Close",
            children: "\u2715"
          }
        ),
        loading ? /* @__PURE__ */ jsxs("div", { className: "space-y-3", children: [
          /* @__PURE__ */ jsx("div", { className: "h-6 animate-pulse rounded bg-border/50 w-1/3" }),
          /* @__PURE__ */ jsx("div", { className: "h-48 animate-pulse rounded bg-border/50" })
        ] }) : !data ? /* @__PURE__ */ jsx("p", { className: "text-muted-foreground text-sm", children: "Picklist not found." }) : /* @__PURE__ */ jsxs(Fragment, { children: [
          /* @__PURE__ */ jsxs("div", { className: "flex items-center gap-3 mb-4", children: [
            /* @__PURE__ */ jsxs("h2", { className: "text-base font-semibold", children: [
              "Picklist ",
              data.picklist.id.slice(0, 8).toUpperCase()
            ] }),
            /* @__PURE__ */ jsx(StatusPill, { status: data.picklist.status }),
            /* @__PURE__ */ jsxs("span", { className: "text-xs text-muted-foreground", children: [
              data.picklist.batchType,
              " \xB7 ",
              data.picklist.orderCount,
              " orders"
            ] })
          ] }),
          /* @__PURE__ */ jsxs("div", { className: "mb-4", children: [
            /* @__PURE__ */ jsx("h3", { className: "text-sm font-medium mb-2", children: "Items by SKU" }),
            /* @__PURE__ */ jsx("div", { className: "rounded-lg border border-border overflow-hidden", children: /* @__PURE__ */ jsxs("table", { className: "w-full text-sm", children: [
              /* @__PURE__ */ jsx("thead", { children: /* @__PURE__ */ jsxs("tr", { className: "border-b border-border bg-muted/50", children: [
                /* @__PURE__ */ jsx("th", { className: "text-left px-3 py-2 font-medium text-muted-foreground", children: "SKU" }),
                /* @__PURE__ */ jsx("th", { className: "text-left px-3 py-2 font-medium text-muted-foreground", children: "Name" }),
                /* @__PURE__ */ jsx("th", { className: "text-left px-3 py-2 font-medium text-muted-foreground", children: "Bin" }),
                /* @__PURE__ */ jsx("th", { className: "text-right px-3 py-2 font-medium text-muted-foreground", children: "Qty" })
              ] }) }),
              /* @__PURE__ */ jsx("tbody", { children: data.skuGroups.map((grp, i) => /* @__PURE__ */ jsxs("tr", { className: "border-b border-border last:border-0", children: [
                /* @__PURE__ */ jsx("td", { className: "px-3 py-2 font-mono text-xs", children: grp.sku || "\u2014" }),
                /* @__PURE__ */ jsx("td", { className: "px-3 py-2", children: grp.name }),
                /* @__PURE__ */ jsx("td", { className: "px-3 py-2 text-muted-foreground", children: grp.binLocation || "\u2014" }),
                /* @__PURE__ */ jsx("td", { className: "px-3 py-2 text-right font-medium", children: grp.totalQuantity })
              ] }, i)) })
            ] }) })
          ] }),
          /* @__PURE__ */ jsxs("div", { className: "mb-4", children: [
            /* @__PURE__ */ jsxs("h3", { className: "text-sm font-medium mb-2", children: [
              "Orders (",
              data.orderRows.length,
              ")"
            ] }),
            /* @__PURE__ */ jsx("div", { className: "space-y-1", children: data.orderRows.map((order) => /* @__PURE__ */ jsxs("div", { className: "flex items-center justify-between px-3 py-2 rounded-md border border-border text-sm", children: [
              /* @__PURE__ */ jsx("span", { className: "font-medium", children: order.externalId || order.id.slice(0, 8) }),
              /* @__PURE__ */ jsx("span", { className: "text-muted-foreground", children: order.customerName }),
              /* @__PURE__ */ jsx(StatusPill, { status: order.status })
            ] }, order.id)) })
          ] }),
          /* @__PURE__ */ jsxs("div", { className: "flex gap-2 mt-5 justify-end", children: [
            /* @__PURE__ */ jsx(
              "button",
              {
                onClick: handlePrint,
                className: "px-3 py-1.5 text-sm font-medium rounded-md bg-foreground text-background hover:bg-foreground/90 transition-colors",
                children: "Print Picklist"
              }
            ),
            data.picklist.status !== "completed" && /* @__PURE__ */ jsx(
              "button",
              {
                onClick: handleComplete,
                disabled: completing,
                className: "px-3 py-1.5 text-sm font-medium rounded-md border border-border text-muted-foreground hover:bg-accent hover:text-foreground transition-colors disabled:opacity-50",
                children: completing ? "Completing..." : "Mark Complete"
              }
            ),
            /* @__PURE__ */ jsx(
              "button",
              {
                onClick: onClose,
                className: "px-3 py-1.5 text-sm font-medium rounded-md border border-border text-muted-foreground hover:text-foreground transition-colors",
                children: "Close"
              }
            )
          ] })
        ] })
      ]
    }
  ) });
}
function AddOrderModal({ onClose, onAdded }) {
  const [saving, setSaving] = useState(false);
  const [form, setForm] = useState({
    externalId: "",
    customerName: "",
    addressLine1: "",
    addressCity: "",
    addressPostcode: "",
    notes: "",
    lineItemsRaw: ""
  });
  const handleSave = async () => {
    setSaving(true);
    let lineItems = [];
    try {
      lineItems = JSON.parse(form.lineItemsRaw || "[]");
    } catch {
      lineItems = form.lineItemsRaw.split("\n").map((l) => l.trim()).filter(Boolean).map((l) => {
        const [sku, ...rest] = l.split(" ");
        return { sku, name: rest.join(" ") || sku, quantity: 1, binLocation: "" };
      });
    }
    await createManualOrder({
      externalId: form.externalId || null,
      customerName: form.customerName,
      customerAddress: {
        line1: form.addressLine1,
        city: form.addressCity,
        postcode: form.addressPostcode
      },
      notes: form.notes,
      lineItems
    });
    setSaving(false);
    onAdded?.();
    onClose();
  };
  return /* @__PURE__ */ jsx("div", { className: "fixed inset-0 z-50 flex items-center justify-center bg-black/50", onClick: onClose, children: /* @__PURE__ */ jsxs(
    "div",
    {
      className: "bg-card border border-border rounded-lg max-w-md w-full mx-4 p-6",
      onClick: (e) => e.stopPropagation(),
      children: [
        /* @__PURE__ */ jsx("h2", { className: "text-base font-semibold mb-4", children: "Add Manual Order" }),
        /* @__PURE__ */ jsxs("div", { className: "space-y-3", children: [
          /* @__PURE__ */ jsxs("div", { children: [
            /* @__PURE__ */ jsx("label", { className: "text-sm text-muted-foreground", children: "Order Reference" }),
            /* @__PURE__ */ jsx(
              "input",
              {
                className: "mt-1 w-full rounded-md border border-border bg-input px-3 py-2 text-sm",
                value: form.externalId,
                onChange: (e) => setForm({ ...form, externalId: e.target.value }),
                placeholder: "e.g. ORD-1234"
              }
            )
          ] }),
          /* @__PURE__ */ jsxs("div", { children: [
            /* @__PURE__ */ jsx("label", { className: "text-sm text-muted-foreground", children: "Customer Name" }),
            /* @__PURE__ */ jsx(
              "input",
              {
                className: "mt-1 w-full rounded-md border border-border bg-input px-3 py-2 text-sm",
                value: form.customerName,
                onChange: (e) => setForm({ ...form, customerName: e.target.value })
              }
            )
          ] }),
          /* @__PURE__ */ jsxs("div", { children: [
            /* @__PURE__ */ jsx("label", { className: "text-sm text-muted-foreground", children: "Address" }),
            /* @__PURE__ */ jsx(
              "input",
              {
                className: "mt-1 w-full rounded-md border border-border bg-input px-3 py-2 text-sm mb-1",
                value: form.addressLine1,
                onChange: (e) => setForm({ ...form, addressLine1: e.target.value }),
                placeholder: "Address line 1"
              }
            ),
            /* @__PURE__ */ jsxs("div", { className: "flex gap-2", children: [
              /* @__PURE__ */ jsx(
                "input",
                {
                  className: "w-full rounded-md border border-border bg-input px-3 py-2 text-sm",
                  value: form.addressCity,
                  onChange: (e) => setForm({ ...form, addressCity: e.target.value }),
                  placeholder: "City"
                }
              ),
              /* @__PURE__ */ jsx(
                "input",
                {
                  className: "w-28 rounded-md border border-border bg-input px-3 py-2 text-sm",
                  value: form.addressPostcode,
                  onChange: (e) => setForm({ ...form, addressPostcode: e.target.value }),
                  placeholder: "Postcode"
                }
              )
            ] })
          ] }),
          /* @__PURE__ */ jsxs("div", { children: [
            /* @__PURE__ */ jsx("label", { className: "text-sm text-muted-foreground", children: "Line Items (JSON or one per line: SKU name)" }),
            /* @__PURE__ */ jsx(
              "textarea",
              {
                rows: 4,
                className: "mt-1 w-full rounded-md border border-border bg-input px-3 py-2 text-sm font-mono",
                value: form.lineItemsRaw,
                onChange: (e) => setForm({ ...form, lineItemsRaw: e.target.value }),
                placeholder: '[{"sku":"AB123","name":"Product","quantity":2,"binLocation":"A1"}]'
              }
            )
          ] }),
          /* @__PURE__ */ jsxs("div", { children: [
            /* @__PURE__ */ jsx("label", { className: "text-sm text-muted-foreground", children: "Notes" }),
            /* @__PURE__ */ jsx(
              "input",
              {
                className: "mt-1 w-full rounded-md border border-border bg-input px-3 py-2 text-sm",
                value: form.notes,
                onChange: (e) => setForm({ ...form, notes: e.target.value })
              }
            )
          ] })
        ] }),
        /* @__PURE__ */ jsxs("div", { className: "mt-5 flex justify-end gap-2", children: [
          /* @__PURE__ */ jsx(
            "button",
            {
              onClick: handleSave,
              disabled: saving,
              className: "px-3 py-1.5 text-sm font-medium rounded-md bg-foreground text-background hover:bg-foreground/90 disabled:opacity-50 transition-colors",
              children: saving ? "Saving..." : "Add Order"
            }
          ),
          /* @__PURE__ */ jsx(
            "button",
            {
              onClick: onClose,
              className: "px-3 py-1.5 text-sm font-medium rounded-md border border-border text-muted-foreground hover:text-foreground transition-colors",
              children: "Cancel"
            }
          )
        ] })
      ]
    }
  ) });
}
function PicklistPage({ session }) {
  const [loading, setLoading] = useState(true);
  const [data, setData] = useState({ pendingCount: 0, recentOrders: [], recentPicklists: [] });
  const [selectedOrderIds, setSelectedOrderIds] = useState(/* @__PURE__ */ new Set());
  const [activeTab, setActiveTab] = useState("orders");
  const [viewingPicklist, setViewingPicklist] = useState(null);
  const [showAddOrder, setShowAddOrder] = useState(false);
  const [actionLoading, setActionLoading] = useState(false);
  const [actionFeedback, setActionFeedback] = useState("");
  const [confirmOvernight, setConfirmOvernight] = useState(false);
  const load = useCallback(async () => {
    setLoading(true);
    const result = await getWarehouseSummary();
    setData(result);
    setLoading(false);
  }, []);
  useEffect(() => {
    load();
  }, [load]);
  useEffect(() => {
    const interval = setInterval(load, 3e4);
    return () => clearInterval(interval);
  }, [load]);
  const feedback = (msg) => {
    setActionFeedback(msg);
    setTimeout(() => setActionFeedback(""), 3e3);
  };
  const handlePrintNext25 = async () => {
    setActionLoading(true);
    const { picklist } = await printNextN(25);
    setActionLoading(false);
    if (picklist) {
      feedback(`Picklist created: ${picklist.id.slice(0, 8).toUpperCase()}`);
      await load();
      setViewingPicklist(picklist.id);
    } else {
      feedback("No pending orders to batch.");
    }
  };
  const handlePrintSelected = async () => {
    if (!selectedOrderIds.size) return;
    setActionLoading(true);
    const { picklist } = await printSelected(Array.from(selectedOrderIds));
    setActionLoading(false);
    setSelectedOrderIds(/* @__PURE__ */ new Set());
    if (picklist) {
      feedback(`Picklist created: ${picklist.id.slice(0, 8).toUpperCase()}`);
      await load();
      setViewingPicklist(picklist.id);
    } else {
      feedback("No pending orders in selection.");
    }
  };
  const handleOvernightBatch = async () => {
    setConfirmOvernight(false);
    setActionLoading(true);
    const { picklist } = await runOvernightBatchAction();
    setActionLoading(false);
    if (picklist) {
      feedback(`Overnight picklist created: ${picklist.orderCount} orders`);
      await load();
      setViewingPicklist(picklist.id);
    } else {
      feedback("No pending orders for overnight batch.");
    }
  };
  const toggleOrderSelect = (id) => {
    setSelectedOrderIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };
  const pendingOrders = data.recentOrders.filter((o) => o.status === "pending");
  const otherOrders = data.recentOrders.filter((o) => o.status !== "pending");
  if (loading) {
    return /* @__PURE__ */ jsx(PageLayout, { session, children: /* @__PURE__ */ jsxs("div", { className: "space-y-3", children: [
      /* @__PURE__ */ jsx("div", { className: "h-8 animate-pulse rounded-md bg-border/50 w-48" }),
      /* @__PURE__ */ jsx("div", { className: "h-24 animate-pulse rounded-md bg-border/50" }),
      /* @__PURE__ */ jsx("div", { className: "h-48 animate-pulse rounded-md bg-border/50" })
    ] }) });
  }
  return /* @__PURE__ */ jsxs(PageLayout, { session, children: [
    /* @__PURE__ */ jsxs("div", { className: "flex items-center justify-between mb-6", children: [
      /* @__PURE__ */ jsxs("div", { children: [
        /* @__PURE__ */ jsx("h1", { className: "text-2xl font-semibold", children: "Warehouse" }),
        /* @__PURE__ */ jsx("p", { className: "text-sm text-muted-foreground mt-0.5", children: "Picklist automation & order fulfilment" })
      ] }),
      /* @__PURE__ */ jsx(
        "button",
        {
          onClick: () => setShowAddOrder(true),
          className: "px-3 py-1.5 text-sm font-medium rounded-md bg-foreground text-background hover:bg-foreground/90 transition-colors",
          children: "+ Add Order"
        }
      )
    ] }),
    /* @__PURE__ */ jsxs("div", { className: "grid grid-cols-3 gap-4 mb-6", children: [
      /* @__PURE__ */ jsxs("div", { className: "rounded-lg border border-border bg-card p-4", children: [
        /* @__PURE__ */ jsx("p", { className: "text-sm text-muted-foreground", children: "Pending Orders" }),
        /* @__PURE__ */ jsx("p", { className: "text-2xl font-semibold mt-1", children: data.pendingCount })
      ] }),
      /* @__PURE__ */ jsxs("div", { className: "rounded-lg border border-border bg-card p-4", children: [
        /* @__PURE__ */ jsx("p", { className: "text-sm text-muted-foreground", children: "Active Picklists" }),
        /* @__PURE__ */ jsx("p", { className: "text-2xl font-semibold mt-1", children: data.recentPicklists.filter((p) => p.status !== "completed").length })
      ] }),
      /* @__PURE__ */ jsxs("div", { className: "rounded-lg border border-border bg-card p-4", children: [
        /* @__PURE__ */ jsx("p", { className: "text-sm text-muted-foreground", children: "Completed Today" }),
        /* @__PURE__ */ jsx("p", { className: "text-2xl font-semibold mt-1", children: data.recentPicklists.filter((p) => {
          if (p.status !== "completed" || !p.completedAt) return false;
          const d = new Date(p.completedAt);
          const now = /* @__PURE__ */ new Date();
          return d.getDate() === now.getDate() && d.getMonth() === now.getMonth();
        }).length })
      ] })
    ] }),
    /* @__PURE__ */ jsxs("div", { className: "flex flex-wrap items-center gap-2 mb-4", children: [
      /* @__PURE__ */ jsx(
        "button",
        {
          onClick: handlePrintNext25,
          disabled: actionLoading || data.pendingCount === 0,
          className: "px-3 py-1.5 text-sm font-medium rounded-md bg-foreground text-background hover:bg-foreground/90 disabled:opacity-50 transition-colors",
          children: "Print next 25"
        }
      ),
      /* @__PURE__ */ jsxs(
        "button",
        {
          onClick: handlePrintSelected,
          disabled: actionLoading || selectedOrderIds.size === 0,
          className: "px-3 py-1.5 text-sm font-medium rounded-md border border-border text-muted-foreground hover:bg-accent hover:text-foreground disabled:opacity-50 transition-colors",
          children: [
            "Print selected (",
            selectedOrderIds.size,
            ")"
          ]
        }
      ),
      /* @__PURE__ */ jsxs(
        "button",
        {
          onClick: () => setConfirmOvernight(true),
          disabled: actionLoading || data.pendingCount === 0,
          className: "px-3 py-1.5 text-sm font-medium rounded-md border border-border text-muted-foreground hover:bg-accent hover:text-foreground disabled:opacity-50 transition-colors",
          children: [
            "Overnight batch (all ",
            data.pendingCount,
            ")"
          ]
        }
      ),
      actionFeedback && /* @__PURE__ */ jsx("span", { className: "text-sm text-green-500", children: actionFeedback })
    ] }),
    confirmOvernight && /* @__PURE__ */ jsxs("div", { className: "mb-4 rounded-lg border border-yellow-500/30 bg-yellow-500/5 p-4", children: [
      /* @__PURE__ */ jsxs("p", { className: "text-sm font-medium text-yellow-500 mb-1", children: [
        "Batch all ",
        data.pendingCount,
        " pending orders?"
      ] }),
      /* @__PURE__ */ jsx("p", { className: "text-sm text-muted-foreground mb-3", children: "This will create a single picklist with all pending orders, with no size cap." }),
      /* @__PURE__ */ jsxs("div", { className: "flex gap-2", children: [
        /* @__PURE__ */ jsx(
          "button",
          {
            onClick: handleOvernightBatch,
            className: "px-3 py-1.5 text-sm font-medium rounded-md bg-yellow-500/20 text-yellow-500 hover:bg-yellow-500/30 transition-colors",
            children: "Yes, batch all"
          }
        ),
        /* @__PURE__ */ jsx(
          "button",
          {
            onClick: () => setConfirmOvernight(false),
            className: "px-3 py-1.5 text-sm font-medium rounded-md border border-border text-muted-foreground hover:bg-accent hover:text-foreground transition-colors",
            children: "Cancel"
          }
        )
      ] })
    ] }),
    /* @__PURE__ */ jsx("div", { className: "flex gap-1 border-b border-border mb-4", children: [
      { id: "orders", label: `Orders (${pendingOrders.length} pending)` },
      { id: "picklists", label: `Picklists (${data.recentPicklists.length})` },
      { id: "history", label: "History" }
    ].map((tab) => /* @__PURE__ */ jsx(
      "button",
      {
        onClick: () => setActiveTab(tab.id),
        className: `px-3 py-2 text-sm font-medium border-b-2 transition-colors ${activeTab === tab.id ? "border-foreground text-foreground" : "border-transparent text-muted-foreground hover:text-foreground hover:border-border"}`,
        children: tab.label
      },
      tab.id
    )) }),
    activeTab === "orders" && /* @__PURE__ */ jsx("div", { className: "space-y-2", children: pendingOrders.length === 0 ? /* @__PURE__ */ jsx("div", { className: "rounded-lg border border-dashed border-border p-8 text-center", children: /* @__PURE__ */ jsx("p", { className: "text-muted-foreground text-sm", children: "No pending orders." }) }) : /* @__PURE__ */ jsx("div", { className: "rounded-lg border border-border overflow-hidden", children: /* @__PURE__ */ jsxs("table", { className: "w-full text-sm", children: [
      /* @__PURE__ */ jsx("thead", { children: /* @__PURE__ */ jsxs("tr", { className: "border-b border-border bg-muted/50", children: [
        /* @__PURE__ */ jsx("th", { className: "px-3 py-2 w-10", children: /* @__PURE__ */ jsx(
          "input",
          {
            type: "checkbox",
            className: "h-4 w-4 rounded border-border",
            checked: selectedOrderIds.size === pendingOrders.length && pendingOrders.length > 0,
            onChange: (e) => {
              if (e.target.checked) {
                setSelectedOrderIds(new Set(pendingOrders.map((o) => o.id)));
              } else {
                setSelectedOrderIds(/* @__PURE__ */ new Set());
              }
            }
          }
        ) }),
        /* @__PURE__ */ jsx("th", { className: "text-left px-3 py-2 font-medium text-muted-foreground", children: "Ref" }),
        /* @__PURE__ */ jsx("th", { className: "text-left px-3 py-2 font-medium text-muted-foreground", children: "Customer" }),
        /* @__PURE__ */ jsx("th", { className: "text-left px-3 py-2 font-medium text-muted-foreground", children: "Items" }),
        /* @__PURE__ */ jsx("th", { className: "text-left px-3 py-2 font-medium text-muted-foreground", children: "Source" }),
        /* @__PURE__ */ jsx("th", { className: "text-left px-3 py-2 font-medium text-muted-foreground", children: "Received" }),
        /* @__PURE__ */ jsx("th", { className: "text-left px-3 py-2 font-medium text-muted-foreground", children: "Status" })
      ] }) }),
      /* @__PURE__ */ jsx("tbody", { children: pendingOrders.map((order) => /* @__PURE__ */ jsxs("tr", { className: "border-b border-border last:border-0 hover:bg-muted/30", children: [
        /* @__PURE__ */ jsx("td", { className: "px-3 py-2", children: /* @__PURE__ */ jsx(
          "input",
          {
            type: "checkbox",
            className: "h-4 w-4 rounded border-border",
            checked: selectedOrderIds.has(order.id),
            onChange: () => toggleOrderSelect(order.id)
          }
        ) }),
        /* @__PURE__ */ jsx("td", { className: "px-3 py-2 font-mono text-xs", children: order.externalId || order.id.slice(0, 8) }),
        /* @__PURE__ */ jsx("td", { className: "px-3 py-2", children: order.customerName || "\u2014" }),
        /* @__PURE__ */ jsxs("td", { className: "px-3 py-2 text-muted-foreground", children: [
          order.lineItems.length,
          " item",
          order.lineItems.length !== 1 ? "s" : ""
        ] }),
        /* @__PURE__ */ jsx("td", { className: "px-3 py-2 text-muted-foreground", children: order.source }),
        /* @__PURE__ */ jsx("td", { className: "px-3 py-2 text-muted-foreground text-xs", children: new Date(order.receivedAt).toLocaleString("en-GB", {
          day: "2-digit",
          month: "short",
          hour: "2-digit",
          minute: "2-digit"
        }) }),
        /* @__PURE__ */ jsx("td", { className: "px-3 py-2", children: /* @__PURE__ */ jsx(StatusPill, { status: order.status }) })
      ] }, order.id)) })
    ] }) }) }),
    activeTab === "picklists" && /* @__PURE__ */ jsx("div", { className: "space-y-2", children: data.recentPicklists.filter((p) => p.status !== "completed").length === 0 ? /* @__PURE__ */ jsx("div", { className: "rounded-lg border border-dashed border-border p-8 text-center", children: /* @__PURE__ */ jsx("p", { className: "text-muted-foreground text-sm", children: "No active picklists." }) }) : /* @__PURE__ */ jsx("div", { className: "rounded-lg border border-border overflow-hidden", children: /* @__PURE__ */ jsxs("table", { className: "w-full text-sm", children: [
      /* @__PURE__ */ jsx("thead", { children: /* @__PURE__ */ jsxs("tr", { className: "border-b border-border bg-muted/50", children: [
        /* @__PURE__ */ jsx("th", { className: "text-left px-3 py-2 font-medium text-muted-foreground", children: "ID" }),
        /* @__PURE__ */ jsx("th", { className: "text-left px-3 py-2 font-medium text-muted-foreground", children: "Type" }),
        /* @__PURE__ */ jsx("th", { className: "text-left px-3 py-2 font-medium text-muted-foreground", children: "Orders" }),
        /* @__PURE__ */ jsx("th", { className: "text-left px-3 py-2 font-medium text-muted-foreground", children: "Created" }),
        /* @__PURE__ */ jsx("th", { className: "text-left px-3 py-2 font-medium text-muted-foreground", children: "Status" }),
        /* @__PURE__ */ jsx("th", { className: "px-3 py-2" })
      ] }) }),
      /* @__PURE__ */ jsx("tbody", { children: data.recentPicklists.filter((p) => p.status !== "completed").map((pl) => /* @__PURE__ */ jsxs("tr", { className: "border-b border-border last:border-0 hover:bg-muted/30", children: [
        /* @__PURE__ */ jsx("td", { className: "px-3 py-2 font-mono text-xs", children: pl.id.slice(0, 8).toUpperCase() }),
        /* @__PURE__ */ jsx("td", { className: "px-3 py-2 text-muted-foreground", children: pl.batchType }),
        /* @__PURE__ */ jsx("td", { className: "px-3 py-2", children: pl.orderCount }),
        /* @__PURE__ */ jsx("td", { className: "px-3 py-2 text-muted-foreground text-xs", children: new Date(pl.createdAt).toLocaleString("en-GB", {
          day: "2-digit",
          month: "short",
          hour: "2-digit",
          minute: "2-digit"
        }) }),
        /* @__PURE__ */ jsx("td", { className: "px-3 py-2", children: /* @__PURE__ */ jsx(StatusPill, { status: pl.status }) }),
        /* @__PURE__ */ jsx("td", { className: "px-3 py-2 text-right", children: /* @__PURE__ */ jsx(
          "button",
          {
            onClick: () => setViewingPicklist(pl.id),
            className: "px-2.5 py-1.5 text-xs font-medium rounded-md border border-border text-muted-foreground hover:bg-accent hover:text-foreground transition-colors",
            children: "View"
          }
        ) })
      ] }, pl.id)) })
    ] }) }) }),
    activeTab === "history" && /* @__PURE__ */ jsx("div", { className: "space-y-2", children: [...pendingOrders, ...otherOrders].filter((o) => o.status !== "pending").length === 0 && data.recentPicklists.filter((p) => p.status === "completed").length === 0 ? /* @__PURE__ */ jsx("div", { className: "rounded-lg border border-dashed border-border p-8 text-center", children: /* @__PURE__ */ jsx("p", { className: "text-muted-foreground text-sm", children: "No completed picklists yet." }) }) : /* @__PURE__ */ jsx(Fragment, { children: data.recentPicklists.filter((p) => p.status === "completed").length > 0 && /* @__PURE__ */ jsx("div", { className: "rounded-lg border border-border overflow-hidden", children: /* @__PURE__ */ jsxs("table", { className: "w-full text-sm", children: [
      /* @__PURE__ */ jsx("thead", { children: /* @__PURE__ */ jsxs("tr", { className: "border-b border-border bg-muted/50", children: [
        /* @__PURE__ */ jsx("th", { className: "text-left px-3 py-2 font-medium text-muted-foreground", children: "Picklist ID" }),
        /* @__PURE__ */ jsx("th", { className: "text-left px-3 py-2 font-medium text-muted-foreground", children: "Type" }),
        /* @__PURE__ */ jsx("th", { className: "text-left px-3 py-2 font-medium text-muted-foreground", children: "Orders" }),
        /* @__PURE__ */ jsx("th", { className: "text-left px-3 py-2 font-medium text-muted-foreground", children: "Completed" }),
        /* @__PURE__ */ jsx("th", { className: "px-3 py-2" })
      ] }) }),
      /* @__PURE__ */ jsx("tbody", { children: data.recentPicklists.filter((p) => p.status === "completed").map((pl) => /* @__PURE__ */ jsxs("tr", { className: "border-b border-border last:border-0 hover:bg-muted/30", children: [
        /* @__PURE__ */ jsx("td", { className: "px-3 py-2 font-mono text-xs", children: pl.id.slice(0, 8).toUpperCase() }),
        /* @__PURE__ */ jsx("td", { className: "px-3 py-2 text-muted-foreground", children: pl.batchType }),
        /* @__PURE__ */ jsx("td", { className: "px-3 py-2", children: pl.orderCount }),
        /* @__PURE__ */ jsx("td", { className: "px-3 py-2 text-muted-foreground text-xs", children: pl.completedAt ? new Date(pl.completedAt).toLocaleString("en-GB", {
          day: "2-digit",
          month: "short",
          hour: "2-digit",
          minute: "2-digit"
        }) : "\u2014" }),
        /* @__PURE__ */ jsx("td", { className: "px-3 py-2 text-right", children: /* @__PURE__ */ jsx(
          "button",
          {
            onClick: () => setViewingPicklist(pl.id),
            className: "px-2.5 py-1.5 text-xs font-medium rounded-md border border-border text-muted-foreground hover:bg-accent hover:text-foreground transition-colors",
            children: "View"
          }
        ) })
      ] }, pl.id)) })
    ] }) }) }) }),
    viewingPicklist && /* @__PURE__ */ jsx(
      PicklistModal,
      {
        picklistId: viewingPicklist,
        onClose: () => setViewingPicklist(null),
        onComplete: load
      }
    ),
    showAddOrder && /* @__PURE__ */ jsx(
      AddOrderModal,
      {
        onClose: () => setShowAddOrder(false),
        onAdded: load
      }
    )
  ] });
}
export {
  PicklistPage
};
