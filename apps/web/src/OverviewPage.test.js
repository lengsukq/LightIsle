import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { compile } from "@vue/compiler-dom";
import { parse } from "@vue/compiler-sfc";
import * as Vue from "vue";

const source = readFileSync(new URL("./OverviewPage.vue", import.meta.url), "utf8");
const template = parse(source, { filename: "OverviewPage.vue" }).descriptor.template.content;
const render = new Function("Vue", compile(template, { mode: "function" }).code)(Vue);
const iconNames = [
  "Activity", "ArrowUpRight", "Clapperboard", "Folder", "HardDrive", "Images",
  "Monitor", "RefreshCcw", "Search", "Server", "ShieldCheck", "WifiOff",
];
const IconStub = Vue.defineComponent({ setup: () => () => null });

const OverviewTestHarness = Vue.defineComponent({
  props: ["identity", "search", "telemetry", "personalSpace"],
  emits: ["search", "return-to-files", "refresh", "navigate", "open-account-settings", "update:query", "update:spotlight", "update:expanded"],
  components: Object.fromEntries(iconNames.map(name => [name, IconStub])),
  setup(props, { emit }) {
    const view = {
      identity: props.identity,
      search: props.search,
      telemetry: props.telemetry,
      personalSpace: props.personalSpace,
      emit,
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
    ...props,
    onSearch: listeners.search,
    onRefresh: listeners.refresh,
    onNavigate: listeners.navigate,
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
    query: value => events.push(["query", value]),
  });
  try {
    assert.match(textContent(mounted.root), /家庭空间一切就绪/);
    assert.match(textContent(mounted.root), /轻屿运行体征/);
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
    assert.deepEqual(events, [["search"], ["query", "photos"], ["search"], ["navigate", "files"], ["refresh"]]);
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
    assert.match(content, /个人空间信息暂时不可用/);
    assert.match(content, /已计入 12 B/);
    assert.doesNotMatch(content, /轻屿运行体征/);
    assert.doesNotMatch(content, /处理器负载/);
  } finally {
    mounted.unmount();
  }
});
