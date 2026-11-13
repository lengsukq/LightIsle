<script setup lang="ts">
import type { Component } from "vue";
import { LogOut, Moon, MoreHorizontal, Sun, X } from "lucide-vue-next";
import AppleSelect, { type SelectOption } from "./AppleSelect.vue";
import type { ShellPage } from "./shellRouteGuard.ts";

export interface NavItemDef {
  key: ShellPage;
  title: string;
  shortTitle: string;
  icon: Component;
  color: string;
  group: string;
}

const props = defineProps<{
  items: NavItemDef[];
  active: ShellPage;
  moreMenuOpen: boolean;
  multiRootMode: boolean;
  rootSelectionValue: string;
  rootSelectionOptions: SelectOption[];
  rootSwitching: boolean;
  showComputerFilesNav: boolean;
  isAdmin: boolean;
  atmosphere: string;
  atmospheres: ReadonlyArray<{ id: string; name: string; icon: string }>;
  theme: "light" | "dark";
}>();

const emit = defineEmits<{
  (e: "select-page", page: ShellPage): void;
  (e: "toggle-more", open: boolean): void;
  (e: "root-change", value: string | number | boolean | null): void;
  (e: "cycle-atmosphere"): void;
  (e: "switch-theme"): void;
  (e: "logout"): void;
}>();

const primaryKeys: ShellPage[] = ["overview", "files", "photos", "cinema"];
const overflowKeys: ShellPage[] = ["computer", "downloads", "apps", "automation", "settings"];

function visibleOverflowItems() {
  return props.items.filter(
    (item) =>
      overflowKeys.includes(item.key) &&
      (item.key !== "automation" || props.isAdmin) &&
      (item.key !== "computer" || props.showComputerFilesNav),
  );
}
</script>

<template>
  <Transition name="mobile-drawer">
    <div v-if="moreMenuOpen" class="mobile-more-backdrop" @click.self="emit('toggle-more', false)">
      <div class="mobile-more-sheet glass" role="dialog" aria-modal="true" aria-label="更多功能与设置">
        <div class="mobile-more-head">
          <strong>更多空间与设置</strong>
          <button type="button" class="circle-action" aria-label="关闭菜单" @click="emit('toggle-more', false)">
            <X :size="16" />
          </button>
        </div>
        <div v-if="multiRootMode" class="mobile-more-root">
          <span>当前共享目录</span>
          <AppleSelect
            :model-value="rootSelectionValue"
            :options="rootSelectionOptions"
            :disabled="rootSwitching"
            size="sm"
            block
            aria-label="选择共享目录"
            @change="emit('root-change', $event)"
          />
        </div>
        <div class="mobile-more-grid">
          <button
            v-for="item in visibleOverflowItems()"
            :key="item.key"
            type="button"
            class="mobile-more-item"
            :class="{ chosen: active === item.key }"
            @click="emit('select-page', item.key); emit('toggle-more', false)"
          >
            <span class="nav-icon-box" :data-color="item.color"><component :is="item.icon" :size="18" /></span>
            <span>{{ item.title }}</span>
          </button>
        </div>
        <div class="mobile-more-footer">
          <button type="button" class="mobile-more-action" @click="emit('cycle-atmosphere')">
            <span>
              {{ atmospheres.find(a => a.id === atmosphere)?.icon }}
              {{ atmospheres.find(a => a.id === atmosphere)?.name }}
            </span>
          </button>
          <button type="button" class="mobile-more-action" @click="emit('switch-theme')">
            <Sun v-if="theme === 'dark'" :size="15" />
            <Moon v-else :size="15" />
            <span>{{ theme === "dark" ? "浅色模式" : "深色模式" }}</span>
          </button>
          <button type="button" class="mobile-more-action danger" @click="emit('toggle-more', false); emit('logout')">
            <LogOut :size="15" />
            <span>退出登录</span>
          </button>
        </div>
      </div>
    </div>
  </Transition>
  <nav class="mobile-nav glass" aria-label="移动导航">
    <button
      v-for="item in items.filter(i => primaryKeys.includes(i.key))"
      :key="item.key"
      type="button"
      :class="{ chosen: active === item.key && !moreMenuOpen }"
      :aria-label="item.title"
      @click="emit('select-page', item.key); emit('toggle-more', false)"
    >
      <component :is="item.icon" :size="20" />
      <span>{{ item.shortTitle }}</span>
    </button>
    <button
      type="button"
      :class="{ chosen: moreMenuOpen || overflowKeys.includes(active) }"
      aria-label="更多与设置"
      @click="emit('toggle-more', !moreMenuOpen)"
    >
      <MoreHorizontal :size="20" />
      <span>{{ overflowKeys.includes(active) ? items.find(i => i.key === active)?.shortTitle : "更多" }}</span>
    </button>
  </nav>
</template>
