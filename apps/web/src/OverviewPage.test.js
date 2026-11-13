import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { compile } from "@vue/compiler-dom";
import { parse } from "@vue/compiler-sfc";
import * as Vue from "vue";
import { ISLE_CHART_COLORS } from "./isleChartsMath.ts";
import { buildHostDiskSegments, buildHostMemorySegments, buildQuotaSegments } from "./overviewPageModels.ts";

const source = readFileSync(new URL("./OverviewPage.vue", import.meta.url), "utf8");
const template = parse(source, { filename: "OverviewPage.vue" }).descriptor.template.content;
const render = new Function("Vue", compile(template, { mode: "function" }).code)(Vue);
const iconNames = [
  "Activity", "ArrowDownToLine", "ArrowUpRight", "Clapperboard", "CopyCheck", "Folder", "HardDrive", "Images",
  "IsleCharts", "Monitor", "RecentSearchPopover", "RefreshCcw", "Search", "Server", "ShieldCheck", "Sparkles", "Trash2", "WifiOff",
];
const IconStub = Vue.defineComponent({ setup: () => () => null });

const OverviewTestHarness = Vue.defineComponent({
  props: ["identity", "search", "telemetry", "personalSpace", "pending"],
  emits: [
    "search", "return-to-files", "refresh", "navigate", "open-account-settings", "open-pending",
    "open-duplicates", "open-trash", "open-similar-photos", "select-history", "delete-history", "clear-history",
    "update:query", "update:spotlight", "update:expanded",
  ],
  components: Object.fromEntries(iconNames.map(name => [name, IconStub])),
  setup(props, { emit }) {
    const view = {
      identity: props.identity,
      search: props.search,
      telemetry: props.telemetry,
      personalSpace: props.personalSpace,
      pending: props.pending,
      emit,
      searchFocused: false,
      searchComposing: false,
      recentOpen: false,
      ISLE_CHART_COLORS,
      cpuSparkPoints: [],
      memSparkPoints: [],
      hostMemorySegments: props.telemetry.stats && !props.telemetry.error && props.telemetry.stats.memoryTotal > 0
        ? buildHostMemorySegments(props.telemetry.stats, props.telemetry.bytes)
        : [],
      hostDiskSegments: props.telemetry.stats && !props.telemetry.error && props.telemetry.stats.diskTotal > 0
        ? buildHostDiskSegments(props.telemetry.stats, props.telemetry.bytes)
        : [],
      personalQuotaCharts: (props.personalSpace.summary?.rootQuotas ?? [])
        .filter((q) => q.quotaBytes !== null && q.quotaBytes > 0)
        .map((q) => ({
          key: `${q.rootID}:${q.rootGeneration}`,
          label: props.personalSpace.rootNames?.[q.rootID] || "存储位置",
          quotaBytes: q.quotaBytes,
          usedPercent: Math.min(100, Math.round(((q.accountedBytes + q.reservedBytes) / q.quotaBytes) * 100)),
          segments: buildQuotaSegments(q.accountedBytes, q.reservedBytes, q.quotaBytes, props.personalSpace.bytes),
        })),
      onSearchKeydown(event) {
        if (event.key === "Enter" && props.search.query.trim().length >= 1) emit("search");
      },
      get query() { return props.search.query; },
      set query(value) { emit("update:query", value.trim()); },
      get spotlight() { return props.search.spotlight; },
      set spotlight(value) { emit("update:spotlight", value); },
    };
    return () => render(view, []);
  },
});

function telemetry() {
  return {
    error: null,
    stats: { architecture: "arm64", cpuCount: 8, memoryUsed: 10, memoryTotal: 20, diskFree: 30, coreRssBytes: 4 },
    polling: false,
    cpu: 12,
    usedMemory: 50,
    usedDisk: 25,
    diskActivity: "空闲",
    expanded: false,
    bytes: value => `${value} B`,
    percent: value => Math.round(value),
  };
}

function textContent(node) {
  return node.text + node.children.map(textContent).join("");
}

function find(node, predicate) {
  if (predicate(node)) return node;
  for (const child of node.children) {
    const match = find(child, predicate);
    if (match) return match;
  }
  return null;
}

function mountOverview(props, listeners) {
  const host = Vue.createRenderer({
    patchProp(element, key, _previous, next) { element.props[key] = next; },
    insert(element, parent, anchor = null) {
      if (element.parent) {
        const previous = element.parent.children.indexOf(element);
        if (previous >= 0) element.parent.children.splice(previous, 1);
      }
      element.parent = parent;
      const index = anchor ? parent.children.indexOf(anchor) : -1;
      parent.children.splice(index < 0 ? parent.children.length : index, 0, element);
    },
    remove(element) {
      if (!element.parent) return;
      const index = element.parent.children.indexOf(element);
      if (index >= 0) element.parent.children.splice(index, 1);
      element.parent = null;
    },
    createElement(type) {
      const element = { type, text: "", props: {}, children: [], parent: null, listeners: {}, value: "" };
      element.addEventListener = (name, handler) => { element.listeners[name] = handler; };
      element.removeEventListener = name => { delete element.listeners[name]; };
      return element;
    },
    createText: text => ({ type: "#text", text, children: [], parent: null }),
    createComment: text => ({ type: "#comment", text, children: [], parent: null }),
    setText(element, text) { element.text = text; },
    setElementText(element, text) { element.text = text; element.children = []; },
    parentNode: element => element.parent,
    nextSibling(element) {
      if (!element.parent) return null;
      return element.parent.children[element.parent.children.indexOf(element) + 1] ?? null;
    },
  });
  const root = { type: "root", text: "", props: {}, children: [], parent: null };
  const app = host.createApp(OverviewTestHarness, {
    pending: {offlineCount: 0, rootsError: "", rootsKnown: true, rootName: "照片盘", tasksLoaded: false, tasksLoading: false, tasksError: "", failedTasks: 0},
    ...props,
    onSearch: listeners.search,
    onRefresh: listeners.refresh,
    onNavigate: listeners.navigate,
    onOpenPending: listeners.pending,
    "onUpdate:query": listeners.query,
  });
  app.mount(root);
  return { root, unmount: () => app.unmount() };
}

test("OverviewPage shows the administrator dashboard and wires search/navigation events", async () => {
  const events = [];
  const mounted = mountOverview({
    identity: { username: "admin", isAdmin: true },
    search: { query: "media", spotlight: false, filesLoading: false, searchingFiles: false },
    telemetry: telemetry(),
    personalSpace: { summary: null, error: "", bytes: value => `${value} B` },
  }, {
    search: () => events.push(["search"]),
    refresh: () => events.push(["refresh"]),
    navigate: page => events.push(["navigate", page]),
    pending: () => events.push(["pending"]),
    query: value => events.push(["query", value]),
  });
  try {
    assert.match(textContent(mounted.root), /管理你的家庭空间/);
    assert.match(textContent(mounted.root), /轻屿运行体征/);
    assert.match(textContent(mounted.root), /待处理数据/);
    assert.match(textContent(mounted.root), /尚未读取/);
    assert.doesNotMatch(textContent(mounted.root), /欢迎回来，admin/);

    const searchButton = find(mounted.root, node => node.type === "button" && node.props.class !== "back-pill" && /搜索共享目录/.test(textContent(node)));
    searchButton.props.onClick();
    const input = find(mounted.root, node => node.type === "input" && node.props.type === "search");
    input.value = "  photos  ";
    input.listeners.input({ target: input });
    input.props.onKeydown({ key: "Enter", preventDefault() {}, stopPropagation() {} });
    const filesCard = find(mounted.root, node => node.type === "button" && node.props.class === "sanctuary-card" && /私人文件/.test(textContent(node)));
    filesCard.props.onClick();
    const refreshButton = find(mounted.root, node => node.type === "button" && /刷新状态/.test(textContent(node)));
    refreshButton.props.onClick();
    const pendingButton = find(mounted.root, node => node.type === "button" && /打开任务中心/.test(textContent(node)));
    pendingButton.props.onClick();
    assert.deepEqual(events, [["search"], ["query", "photos"], ["search"], ["navigate", "files"], ["refresh"], ["pending"]]);
  } finally {
    mounted.unmount();
  }
});

test("OverviewPage shows member identity and personal-space status without admin telemetry", () => {
  const mounted = mountOverview({
    identity: { username: "小岛", isAdmin: false },
    search: { query: "", spotlight: false, filesLoading: false, searchingFiles: false },
    telemetry: telemetry(),
    personalSpace: {
      summary: {
        quotaBytes: null,
        rootQuotas: [],
        accountedBytes: 12,
        reservedBytes: 3,
        usageComplete: false,
        enforcement: "pending",
        locations: [{ category: "files", rootID: "root-a" }],
      },
      error: "个人空间信息暂时不可用",
      bytes: value => `${value} B`,
    },
  }, {});
  try {
    const content = textContent(mounted.root);
    assert.match(content, /欢迎回来，小岛/);
    assert.match(content, /我的空间/);
    assert.match(content, /下载中心/);
    assert.match(content, /已授权个人空间/);
    assert.match(content, /个人空间信息暂时不可用/);
    assert.match(content, /已计入 12 B/);
    assert.doesNotMatch(content, /本机服务在线/);
    assert.doesNotMatch(content, /轻屿运行体征/);
    assert.doesNotMatch(content, /处理器负载/);
    assert.doesNotMatch(content, /待处理数据/);
  } finally {
    mounted.unmount();
  }
});

test("administrator pending overview reports offline disks and incomplete state", () => {
  const mounted = mountOverview({
    identity: { username: "admin", isAdmin: true },
    search: { query: "", spotlight: false, filesLoading: false, searchingFiles: false },
    telemetry: telemetry(),
    personalSpace: { summary: null, error: "", bytes: value => `${value} B` },
    pending: {offlineCount: 2, rootsError: "", rootsKnown: true, rootName: "照片盘", tasksLoaded: true, tasksLoading: false, tasksError: "", failedTasks: 1},
  }, {});
  try {
    const content = textContent(mounted.root);
    assert.match(content, /2 块已登记硬盘离线/);
    assert.match(content, /照片盘：1 项任务未完成/);
    assert.match(content, /不代表所有数据已核对/);
  } finally {
    mounted.unmount();
  }
});

test("OverviewPage allows navigating to downloads for members and blocks short whitespace Enter", () => {
  const events = [];
  const mounted = mountOverview({
    identity: { username: "小岛", isAdmin: false },
    search: { query: "   ", spotlight: false, filesLoading: false, searchingFiles: false },
    telemetry: telemetry(),
    personalSpace: { summary: null, error: "", bytes: value => `${value} B` },
  }, {
    search: () => events.push(["search"]),
    navigate: page => events.push(["navigate", page]),
  });
  try {
    const input = find(mounted.root, node => node.type === "input" && node.props.type === "search");
    input.props.onKeydown({ key: "Enter", preventDefault() {}, stopPropagation() {} });
    const downloadsCard = find(mounted.root, node => node.type === "button" && node.props.class === "sanctuary-card" && /下载中心/.test(textContent(node)));
    downloadsCard.props.onClick();
    assert.deepEqual(events, [["navigate", "downloads"]]);
    assert.doesNotMatch(source, /update:query.*value\.trim/);
  } finally {
    mounted.unmount();
  }
});
