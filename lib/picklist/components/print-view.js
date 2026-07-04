"use client";
import { Fragment, jsx, jsxs } from "react/jsx-runtime";
import { useState, useEffect } from "react";
import { getPicklistBatch } from "../actions.js";
function formatDate(epoch) {
  if (!epoch) return "\u2014";
  return new Date(epoch * 1e3).toLocaleString("en-GB", {
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    timeZone: "UTC",
    timeZoneName: "short"
  });
}
function formatPlatform(p) {
  if (!p || p === "unknown") return "\u2014";
  return p.charAt(0).toUpperCase() + p.slice(1).replace(/_/g, " ");
}
function batchTypeLabel(type) {
  switch (type) {
    case "morning":
      return "Morning Batch";
    case "auto":
      return "Auto Batch";
    default:
      return "Manual Batch";
  }
}
function qrUrl(orderId, scanBaseUrl) {
  const data = scanBaseUrl ? `${scanBaseUrl}/api/picklist/scan?order_id=${orderId}` : String(orderId);
  return `https://api.qrserver.com/v1/create-qr-code/?size=96x96&margin=2&data=${encodeURIComponent(data)}`;
}
function SkuSection({ group, scanBaseUrl }) {
  return /* @__PURE__ */ jsxs("div", { className: "sku-section", children: [
    /* @__PURE__ */ jsxs("div", { className: "sku-header", children: [
      /* @__PURE__ */ jsx("span", { className: "sku-badge", children: group.sku }),
      /* @__PURE__ */ jsx("span", { className: "sku-name", children: group.name }),
      /* @__PURE__ */ jsxs("span", { className: "sku-total", children: [
        "Total qty: ",
        /* @__PURE__ */ jsx("strong", { children: group.total_qty })
      ] })
    ] }),
    /* @__PURE__ */ jsxs("table", { children: [
      /* @__PURE__ */ jsx("thead", { children: /* @__PURE__ */ jsxs("tr", { children: [
        /* @__PURE__ */ jsx("th", { children: "Order" }),
        /* @__PURE__ */ jsx("th", { children: "Platform" }),
        /* @__PURE__ */ jsx("th", { children: "Customer" }),
        /* @__PURE__ */ jsx("th", { style: { textAlign: "center" }, children: "Qty" }),
        /* @__PURE__ */ jsx("th", { style: { textAlign: "center" }, children: "Scan to print label" })
      ] }) }),
      /* @__PURE__ */ jsx("tbody", { children: group.lines.map((line) => /* @__PURE__ */ jsxs("tr", { children: [
        /* @__PURE__ */ jsxs("td", { className: "order-id", children: [
          "#",
          line.order_id
        ] }),
        /* @__PURE__ */ jsx("td", { className: "platform", children: formatPlatform(line.platform) }),
        /* @__PURE__ */ jsx("td", { className: "customer", children: line.customer }),
        /* @__PURE__ */ jsx("td", { className: "qty", children: line.quantity }),
        /* @__PURE__ */ jsx("td", { className: "qr-cell", children: /* @__PURE__ */ jsx(
          "img",
          {
            src: qrUrl(line.order_id, scanBaseUrl),
            alt: `Scan order ${line.order_id}`,
            width: 80,
            height: 80
          }
        ) })
      ] }, line.order_id)) })
    ] })
  ] });
}
function PrintView({ batchId, scanBaseUrl, autoprint }) {
  const [batch, setBatch] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  useEffect(() => {
    getPicklistBatch(batchId).then((data) => {
      if (data.error) {
        setError(data.error);
        return;
      }
      setBatch(data);
    }).catch((e) => setError(e.message)).finally(() => setLoading(false));
  }, [batchId]);
  useEffect(() => {
    if (batch && autoprint) {
      const t = setTimeout(() => window.print(), 800);
      return () => clearTimeout(t);
    }
  }, [batch, autoprint]);
  if (loading) {
    return /* @__PURE__ */ jsx("div", { className: "loading", children: "Loading picklist\u2026" });
  }
  if (error || !batch) {
    return /* @__PURE__ */ jsxs("div", { className: "loading", children: [
      "Error: ",
      error || "Batch not found"
    ] });
  }
  const typeLabel = batchTypeLabel(batch.type);
  return /* @__PURE__ */ jsxs(Fragment, { children: [
    /* @__PURE__ */ jsx("style", { children: `
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
          font-family: Arial, sans-serif;
          font-size: 11pt;
          color: #000;
          background: #fff;
          padding: 12mm 15mm;
        }
        .header {
          border-bottom: 2px solid #000;
          padding-bottom: 8px;
          margin-bottom: 16px;
          display: flex;
          justify-content: space-between;
          align-items: flex-end;
        }
        .header h1 { font-size: 18pt; font-weight: 700; }
        .batch-badge {
          display: inline-block;
          background: #000;
          color: #fff;
          font-size: 8pt;
          font-weight: 700;
          padding: 2px 6px;
          border-radius: 3px;
          margin-left: 8px;
          vertical-align: middle;
        }
        .meta { text-align: right; font-size: 9pt; color: #444; }
        .meta strong { font-size: 11pt; color: #000; }
        .sku-section {
          margin-bottom: 16px;
          break-inside: avoid;
          page-break-inside: avoid;
        }
        .sku-header {
          background: #f0f0f0;
          border: 1px solid #ccc;
          border-bottom: none;
          padding: 5px 8px;
          display: flex;
          align-items: center;
          gap: 10px;
        }
        .sku-badge {
          font-family: monospace;
          font-weight: 700;
          font-size: 10pt;
          background: #333;
          color: #fff;
          padding: 2px 6px;
          border-radius: 3px;
        }
        .sku-name { flex: 1; font-weight: 600; }
        .sku-total { font-size: 9pt; color: #444; }
        table {
          width: 100%;
          border-collapse: collapse;
          font-size: 10pt;
        }
        thead th {
          background: #333;
          color: #fff;
          text-align: left;
          padding: 4px 8px;
          font-size: 9pt;
          font-weight: 600;
        }
        tbody tr { border-bottom: 1px solid #ddd; }
        tbody tr:nth-child(even) { background: #fafafa; }
        tbody td { padding: 4px 8px; vertical-align: middle; }
        .order-id { font-family: monospace; font-weight: 700; font-size: 10pt; }
        .qty { font-size: 13pt; font-weight: 700; text-align: center; width: 60px; }
        .qr-cell { text-align: center; width: 100px; padding: 3px; }
        .qr-cell img { display: block; margin: auto; }
        .platform { font-size: 9pt; color: #444; width: 110px; }
        .customer { font-size: 9pt; max-width: 190px; }
        .footer {
          margin-top: 16px;
          border-top: 1px solid #ccc;
          padding-top: 6px;
          font-size: 8pt;
          color: #888;
          text-align: center;
        }
        .no-print { display: none; }
        @media screen {
          body { background: #f5f5f5; padding: 20px; }
          .page { background: #fff; max-width: 860px; margin: 0 auto; padding: 24px; box-shadow: 0 1px 4px rgba(0,0,0,0.15); }
          .no-print { display: flex !important; }
          .print-bar {
            display: flex;
            justify-content: space-between;
            align-items: center;
            max-width: 860px;
            margin: 0 auto 16px;
            gap: 8px;
          }
          .print-btn {
            background: #000;
            color: #fff;
            border: none;
            padding: 8px 16px;
            border-radius: 6px;
            font-size: 13px;
            cursor: pointer;
            display: flex;
            align-items: center;
            gap: 6px;
          }
          .print-btn:hover { background: #222; }
          .batch-info { font-size: 12px; color: #666; font-family: monospace; }
        }
        @media print {
          body { background: #fff; padding: 8mm 10mm; }
          .page { padding: 0; box-shadow: none; }
        }
      ` }),
    /* @__PURE__ */ jsxs("div", { className: "no-print print-bar", children: [
      /* @__PURE__ */ jsx("span", { className: "batch-info", children: batch.batch_id }),
      /* @__PURE__ */ jsx("button", { className: "print-btn", onClick: () => window.print(), children: "\u{1F5A8} Print picklist" })
    ] }),
    /* @__PURE__ */ jsxs("div", { className: "page", children: [
      /* @__PURE__ */ jsxs("div", { className: "header", children: [
        /* @__PURE__ */ jsxs("div", { children: [
          /* @__PURE__ */ jsxs("h1", { children: [
            "ArryBarry Picklist",
            /* @__PURE__ */ jsx("span", { className: "batch-badge", children: typeLabel })
          ] }),
          /* @__PURE__ */ jsxs("div", { style: { marginTop: "4px", fontSize: "9pt", color: "#555" }, children: [
            "Batch: ",
            batch.batch_id
          ] })
        ] }),
        /* @__PURE__ */ jsxs("div", { className: "meta", children: [
          /* @__PURE__ */ jsx("strong", { children: formatDate(batch.created_at) }),
          /* @__PURE__ */ jsxs("div", { style: { marginTop: "4px" }, children: [
            batch.order_count,
            " order",
            batch.order_count !== 1 ? "s" : "",
            " \xA0|\xA0",
            " ",
            batch.sku_groups.length,
            " SKU",
            batch.sku_groups.length !== 1 ? "s" : ""
          ] })
        ] })
      ] }),
      batch.sku_groups.map((group) => /* @__PURE__ */ jsx(
        SkuSection,
        {
          group,
          scanBaseUrl
        },
        group.product_id
      )),
      /* @__PURE__ */ jsxs("div", { className: "footer", children: [
        "Scan QR code at pack station to print shipping label \xA0|\xA0 ArryBarry BigMan Engine \xA0|\xA0 ",
        batch.batch_id
      ] })
    ] })
  ] });
}
export {
  PrintView
};
