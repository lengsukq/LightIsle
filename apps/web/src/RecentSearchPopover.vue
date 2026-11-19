<script setup lang="ts">
import { Clock, X } from "lucide-vue-next";

defineProps<{
  open: boolean;
  items: string[];
}>();

const emit = defineEmits<{
  select: [query: string];
  delete: [query: string];
  clear: [];
}>();
</script>

<template>
  <div v-if="open && items.length" class="recent-search-popover" role="region" aria-label="最近搜索记录" @mousedown.prevent>
    <div class="recent-search-head">
      <span><Clock :size="12" /> 最近搜索</span>
      <button type="button" class="recent-search-clear" @click="emit('clear')">清空</button>
    </div>
    <div class="recent-search-pills">
      <div v-for="term in items" :key="term" class="recent-search-pill">
        <button type="button" class="recent-search-term" :title="'再次搜索：' + term" @click="emit('select', term)">
          {{ term }}
        </button>
        <button type="button" class="recent-search-del" :aria-label="'移除搜索记录 ' + term" title="移除" @click.stop="emit('delete', term)">
          <X :size="11" />
        </button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.recent-search-popover {
  position: absolute;
  top: calc(100% + 5px);
  left: 0;
  right: 0;
  min-width: 230px;
  z-index: 60;
  padding: 9px 11px;
  border-radius: 12px;
  background: var(--fluid-card-fill);
  backdrop-filter: blur(20px) saturate(175%);
  -webkit-backdrop-filter: blur(20px) saturate(175%);
  border: 1px solid var(--fluid-card-border);
  box-shadow: 0 12px 28px -6px rgba(15, 23, 42, 0.16);
  display: grid;
  gap: 7px;
}
.recent-search-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  font-size: 11px;
  font-weight: 600;
  color: var(--text-secondary);
}
.recent-search-head span {
  display: inline-flex;
  align-items: center;
  gap: 4px;
}
.recent-search-clear {
  border: 0 !important;
  background: transparent !important;
  box-shadow: none !important;
  padding: 2px 5px !important;
  min-height: auto !important;
  font-size: 11px;
  font-weight: 600;
  color: var(--text-tertiary);
  cursor: pointer;
}
.recent-search-clear:hover {
  color: var(--accent-primary);
}
.recent-search-pills {
  display: flex;
  flex-wrap: wrap;
  gap: 5px;
}
.recent-search-pill {
  display: inline-flex;
  align-items: center;
  border-radius: 999px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  overflow: hidden;
  max-width: 100%;
  transition: border-color 0.15s ease, background-color 0.15s ease;
}
.recent-search-pill:hover {
  border-color: color-mix(in srgb, var(--accent-primary) 38%, var(--fluid-card-border));
}
.recent-search-term,
.recent-search-del {
  border: 0 !important;
  background: transparent !important;
  box-shadow: none !important;
  min-height: auto !important;
  cursor: pointer;
}
.recent-search-term {
  padding: 3px 4px 3px 9px !important;
  font-size: 11.5px;
  color: var(--text-primary);
  max-width: 170px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.recent-search-del {
  padding: 3px 6px 3px 3px !important;
  color: var(--text-tertiary);
  display: inline-flex;
  align-items: center;
}
.recent-search-del:hover {
  color: var(--error);
}
@media (prefers-reduced-motion: reduce) {
  .recent-search-pill {
    transition: none;
  }
}
</style>
