<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import {
  ChevronLeft,
  ChevronRight,
  MessageSquareHeart,
  Pin,
  PinOff,
  Plus,
  Send,
  Trash2,
  X,
} from "lucide-vue-next";
import { apiRequest } from "../../api/apiClient.ts";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IslePageHeader from "../../components/ui/IslePageHeader.vue";
import "./FamilyBoardCarousel.css";

export interface FamilyBoardMessage {
  id: number;
  authorUserId: number;
  authorUsername: string;
  authorRole: "admin" | "member" | string;
  content: string;
  tag: string;
  color: string;
  pinned: boolean;
  pinnedAt?: number;
  pinnedBy?: string;
  createdAt: number;
}

interface BoardListResponse {
  messages?: FamilyBoardMessage[];
  isAdmin?: boolean;
  currentUserId?: number;
  currentUsername?: string;
}

const props = defineProps<{
  isAdmin: boolean;
  username: string;
}>();

const BOARD_TAGS = ["留言", "提醒", "采购", "心愿"] as const;
const BOARD_COLORS = [
  { id: "amber", label: "暖阳" },
  { id: "blue", label: "晴空" },
  { id: "rose", label: "晚霞" },
  { id: "sage", label: "青苔" },
  { id: "violet", label: "暮紫" },
] as const;

const messages = ref<FamilyBoardMessage[]>([]);
const currentUserId = ref<number>(0);
const loading = ref(false);
const loadError = ref("");
const activeIndex = ref(0);
const swipeDirection = ref<"next" | "prev">("next");

// Composer state
const composerOpen = ref(false);
const draftContent = ref("");
const draftTag = ref<string>("留言");
const draftColor = ref<string>("amber");
const submitting = ref(false);
const submitError = ref("");

// Action states
const busyId = ref<number | null>(null);
const confirmDeleteId = ref<number | null>(null);

// Pointer / Touch swipe physics state
const dragActive = ref(false);
const dragStartX = ref(0);
const dragStartY = ref(0);
const dragStartTime = ref(0);
const dragOffsetX = ref(0);
const dragAxisLocked = ref<"x" | "y" | null>(null);
const activePointerId = ref<number | null>(null);

const currentMessage = computed<FamilyBoardMessage | null>(() => {
  if (!messages.value.length) return null;
  const idx = Math.min(Math.max(activeIndex.value, 0), messages.value.length - 1);
  return messages.value[idx] ?? null;
});

const swipeTransitionName = computed(() =>
  swipeDirection.value === "next" ? "board-slide-next" : "board-slide-prev",
);

const cardInlineStyle = computed(() => {
  if (!dragActive.value || dragOffsetX.value === 0) return {};
  if (typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches) {
    return {};
  }
  const offset = dragOffsetX.value;
  const tilt = Math.max(-4.5, Math.min(4.5, offset * 0.022));
  const scale = Math.max(0.96, 1 - Math.abs(offset) * 0.00025);
  return {
    transform: `translate3d(${offset}px, 0, 0) rotate(${tilt}deg) scale(${scale})`,
    transition: "none",
  };
});

function canDelete(msg: FamilyBoardMessage): boolean {
  if (props.isAdmin) return true;
  if (currentUserId.value > 0 && msg.authorUserId === currentUserId.value) return true;
  return Boolean(props.username) && msg.authorUsername.toLowerCase() === props.username.toLowerCase();
}

function formatRelativeTime(unixSeconds: number): string {
  if (!unixSeconds || !Number.isFinite(unixSeconds)) return "";
  const nowSec = Math.floor(Date.now() / 1000);
  const diff = Math.max(0, nowSec - unixSeconds);
  if (diff < 60) return "刚刚";
  if (diff < 3600) return `${Math.floor(diff / 60)} 分钟前`;
  if (diff < 86400) return `${Math.floor(diff / 3600)} 小时前`;
  const d = new Date(unixSeconds * 1000);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function avatarInitial(name: string): string {
  const clean = (name || "").trim();
  return clean ? clean.slice(0, 1).toUpperCase() : "家";
}

function colorClass(color?: string): string {
  const allowed = new Set(["amber", "blue", "rose", "sage", "violet"]);
  return `tone-${color && allowed.has(color) ? color : "amber"}`;
}

async function fetchMessages(preserveMessageId?: number) {
  loading.value = true;
  loadError.value = "";
  try {
    const res = await apiRequest<BoardListResponse>("/api/v2/board/messages?limit=50");
    const list = Array.isArray(res?.messages) ? res.messages : [];
    messages.value = list;
    if (typeof res?.currentUserId === "number") {
      currentUserId.value = res.currentUserId;
    }
    if (preserveMessageId != null) {
      const idx = list.findIndex((m) => m.id === preserveMessageId);
      activeIndex.value = idx >= 0 ? idx : 0;
    } else if (activeIndex.value >= list.length) {
      activeIndex.value = Math.max(0, list.length - 1);
    }
  } catch (err) {
    loadError.value = err instanceof Error ? err.message : "留言板暂时无法读取";
  } finally {
    loading.value = false;
  }
}

function goTo(index: number) {
  if (!messages.value.length) return;
  const bounded = Math.max(0, Math.min(messages.value.length - 1, index));
  if (bounded === activeIndex.value) return;
  swipeDirection.value = bounded > activeIndex.value ? "next" : "prev";
  confirmDeleteId.value = null;
  activeIndex.value = bounded;
}

function goNext() {
  if (activeIndex.value < messages.value.length - 1) {
    goTo(activeIndex.value + 1);
  }
}

function goPrev() {
  if (activeIndex.value > 0) {
    goTo(activeIndex.value - 1);
  }
}

function onPointerDown(event: PointerEvent) {
  if (messages.value.length <= 1) return;
  const target = event.target as HTMLElement | null;
  if (target?.closest("button, a, textarea, input")) return;
  if (event.pointerType === "mouse" && event.button !== 0) return;
  activePointerId.value = event.pointerId;
  dragActive.value = true;
  dragStartX.value = event.clientX;
  dragStartY.value = event.clientY;
  dragStartTime.value = performance.now();
  dragOffsetX.value = 0;
  dragAxisLocked.value = null;
  (event.currentTarget as HTMLElement | null)?.setPointerCapture?.(event.pointerId);
}

function onPointerMove(event: PointerEvent) {
  if (!dragActive.value || activePointerId.value !== event.pointerId) return;
  const dx = event.clientX - dragStartX.value;
  const dy = event.clientY - dragStartY.value;
  if (dragAxisLocked.value === null) {
    if (Math.abs(dx) < 8 && Math.abs(dy) < 8) return;
    dragAxisLocked.value = Math.abs(dx) >= Math.abs(dy) ? "x" : "y";
  }
  if (dragAxisLocked.value !== "x") {
    dragActive.value = false;
    dragOffsetX.value = 0;
    return;
  }
  const atStart = activeIndex.value === 0 && dx > 0;
  const atEnd = activeIndex.value === messages.value.length - 1 && dx < 0;
  dragOffsetX.value = atStart || atEnd ? dx * 0.28 : Math.max(-180, Math.min(180, dx));
}

function finishPointerDrag(event: PointerEvent) {
  if (!dragActive.value || activePointerId.value !== event.pointerId) return;
  const offset = dragOffsetX.value;
  const elapsed = Math.max(1, performance.now() - dragStartTime.value);
  const velocity = Math.abs(offset) / elapsed;
  dragActive.value = false;
  dragOffsetX.value = 0;
  dragAxisLocked.value = null;
  activePointerId.value = null;
  if (Math.abs(offset) >= 48 || (Math.abs(offset) >= 24 && velocity >= 0.35)) {
    if (offset < 0) goNext();
    else goPrev();
  }
}

function onDeckKeydown(event: KeyboardEvent) {
  if (event.key === "ArrowRight") {
    event.preventDefault();
    goNext();
  } else if (event.key === "ArrowLeft") {
    event.preventDefault();
    goPrev();
  }
}

async function submitMessage() {
  const text = draftContent.value.trim();
  if (!text || submitting.value) return;
  submitting.value = true;
  submitError.value = "";
  try {
    const res = await apiRequest<{ message: FamilyBoardMessage }>("/api/v2/board/messages", {
      method: "POST",
      json: {
        content: text,
        tag: draftTag.value,
        color: draftColor.value,
      },
    });
    draftContent.value = "";
    composerOpen.value = false;
    swipeDirection.value = "prev";
    await fetchMessages(res?.message?.id);
  } catch (err) {
    submitError.value = err instanceof Error ? err.message : "发布失败，请稍后重试";
  } finally {
    submitting.value = false;
  }
}

async function togglePin(msg: FamilyBoardMessage) {
  if (!props.isAdmin || busyId.value !== null) return;
  busyId.value = msg.id;
  try {
    await apiRequest(`/api/v2/board/messages/${msg.id}/pin`, {
      method: "PATCH",
      json: { pinned: !msg.pinned },
    });
    swipeDirection.value = !msg.pinned ? "prev" : "next";
    await fetchMessages(msg.id);
  } catch (err) {
    loadError.value = err instanceof Error ? err.message : "更新置顶状态失败";
  } finally {
    busyId.value = null;
  }
}

async function removeMessage(msg: FamilyBoardMessage) {
  if (!canDelete(msg) || busyId.value !== null) return;
  if (confirmDeleteId.value !== msg.id) {
    confirmDeleteId.value = msg.id;
    return;
  }
  busyId.value = msg.id;
  confirmDeleteId.value = null;
  try {
    await apiRequest(`/api/v2/board/messages/${msg.id}`, { method: "DELETE" });
    await fetchMessages();
  } catch (err) {
    loadError.value = err instanceof Error ? err.message : "删除留言失败";
  } finally {
    busyId.value = null;
  }
}

onMounted(() => {
  void fetchMessages();
});
</script>

<template>
  <section class="family-board-section" aria-label="家庭留言板">
    <IslePageHeader title="家庭留言板" compact>
      <template #actions>
        <IsleBadge v-if="messages.length > 0" variant="neutral" size="sm">
          {{ activeIndex + 1 }} / {{ messages.length }}
        </IsleBadge>
        <IsleButton
          variant="glass"
          size="sm"
          @click="composerOpen = !composerOpen; submitError = ''"
        >
          <template #icon>
            <X v-if="composerOpen" :size="14" />
            <Plus v-else :size="14" />
          </template>
          {{ composerOpen ? "收起" : "写一条留言" }}
        </IsleButton>
      </template>
    </IslePageHeader>

    <Transition name="board-composer">
      <form v-if="composerOpen" class="board-composer-card" @submit.prevent="submitMessage">
        <div class="board-composer-top">
          <div class="board-tag-row" role="radiogroup" aria-label="留言分类">
            <button
              v-for="tag in BOARD_TAGS"
              :key="tag"
              type="button"
              class="board-pill-choice"
              :class="{ active: draftTag === tag }"
              @click="draftTag = tag"
            >
              {{ tag }}
            </button>
          </div>
          <div class="board-color-row" role="radiogroup" aria-label="卡片色调">
            <button
              v-for="c in BOARD_COLORS"
              :key="c.id"
              type="button"
              class="board-color-dot"
              :class="[`dot-${c.id}`, { active: draftColor === c.id }]"
              :title="c.label"
              :aria-label="`卡片色调：${c.label}`"
              @click="draftColor = c.id"
            />
          </div>
        </div>
        <textarea
          v-model="draftContent"
          class="board-textarea"
          rows="3"
          maxlength="500"
          placeholder="给家人留个言吧：今晚想吃什么、顺路买点东西，或者周末安排…"
          aria-label="留言内容"
        />
        <div class="board-composer-foot">
          <span class="board-char-count">{{ draftContent.trim().length }} / 500</span>
          <span v-if="submitError" class="board-inline-error" role="alert">{{ submitError }}</span>
          <IsleButton
            type="submit"
            variant="primary"
            size="sm"
            :disabled="submitting || draftContent.trim().length === 0"
          >
            <template #icon><Send :size="13" /></template>
            {{ submitting ? "发布中…" : "发布留言" }}
          </IsleButton>
        </div>
      </form>
    </Transition>

    <div v-if="currentMessage" class="board-stage-shell">
      <div
        class="board-deck-viewport"
        tabindex="0"
        role="region"
        aria-roledescription="carousel"
        aria-label="家庭留言卡片，支持左右滑动切换"
        @pointerdown="onPointerDown"
        @pointermove="onPointerMove"
        @pointerup="finishPointerDrag"
        @pointercancel="finishPointerDrag"
        @keydown="onDeckKeydown"
      >
        <div v-if="messages.length > 2" class="board-deck-ghost board-deck-ghost-2" aria-hidden="true" />
        <div v-if="messages.length > 1" class="board-deck-ghost board-deck-ghost-1" aria-hidden="true" />

        <Transition :name="swipeTransitionName" mode="out-in">
          <article
            :key="currentMessage.id"
            class="board-card"
            :class="[colorClass(currentMessage.color), { 'is-pinned': currentMessage.pinned, 'is-dragging': dragActive }]"
            :style="cardInlineStyle"
          >
            <div class="board-card-head">
              <div class="board-author">
                <span class="board-avatar">{{ avatarInitial(currentMessage.authorUsername) }}</span>
                <div class="board-author-meta">
                  <div class="board-author-row">
                    <strong>{{ currentMessage.authorUsername }}</strong>
                    <span class="board-role-tag">{{ currentMessage.authorRole === "admin" ? "管理员" : "家人" }}</span>
                    <span class="board-tag-chip">{{ currentMessage.tag || "留言" }}</span>
                  </div>
                  <small>{{ formatRelativeTime(currentMessage.createdAt) }}</small>
                </div>
              </div>
              <div class="board-card-actions">
                <span v-if="currentMessage.pinned" class="board-pin-badge">
                  <Pin :size="12" /> 已置顶
                </span>
                <button
                  v-if="isAdmin"
                  type="button"
                  class="board-icon-btn"
                  :class="{ active: currentMessage.pinned }"
                  :disabled="busyId === currentMessage.id"
                  :title="currentMessage.pinned ? '取消置顶' : '置顶此留言'"
                  :aria-label="currentMessage.pinned ? '取消置顶' : '置顶此留言'"
                  @click="togglePin(currentMessage)"
                >
                  <PinOff v-if="currentMessage.pinned" :size="14" />
                  <Pin v-else :size="14" />
                </button>
                <button
                  v-if="canDelete(currentMessage)"
                  type="button"
                  class="board-icon-btn danger"
                  :class="{ confirming: confirmDeleteId === currentMessage.id }"
                  :disabled="busyId === currentMessage.id"
                  :title="confirmDeleteId === currentMessage.id ? '再次点击确认删除' : '删除留言'"
                  :aria-label="confirmDeleteId === currentMessage.id ? '确认删除留言' : '删除留言'"
                  @click="removeMessage(currentMessage)"
                >
                  <Trash2 :size="14" />
                  <span v-if="confirmDeleteId === currentMessage.id" class="confirm-text">确认?</span>
                </button>
              </div>
            </div>

            <p class="board-card-body">{{ currentMessage.content }}</p>

            <div class="board-card-foot">
              <span class="board-swipe-hint">
                {{ messages.length > 1 ? "左右滑动切换留言" : "最新家庭留言" }}
              </span>
              <span v-if="currentMessage.pinned && currentMessage.pinnedBy" class="board-pin-meta">
                由 {{ currentMessage.pinnedBy }} 置顶
              </span>
            </div>
          </article>
        </Transition>
      </div>

      <div v-if="messages.length > 1" class="board-controls">
        <button
          type="button"
          class="board-nav-btn"
          :disabled="activeIndex <= 0"
          aria-label="上一条留言"
          @click="goPrev"
        >
          <ChevronLeft :size="16" />
        </button>
        <div class="board-dots" role="tablist" aria-label="切换留言">
          <button
            v-for="(m, idx) in messages.slice(0, 12)"
            :key="m.id"
            type="button"
            class="board-dot"
            :class="{ active: idx === activeIndex, pinned: m.pinned }"
            :aria-label="`第 ${idx + 1} 条留言`"
            :aria-selected="idx === activeIndex"
            @click="goTo(idx)"
          />
          <span v-if="messages.length > 12" class="board-dot-more">+{{ messages.length - 12 }}</span>
        </div>
        <button
          type="button"
          class="board-nav-btn"
          :disabled="activeIndex >= messages.length - 1"
          aria-label="下一条留言"
          @click="goNext"
        >
          <ChevronRight :size="16" />
        </button>
      </div>
    </div>

    <div v-else-if="!loading" class="board-empty-card">
      <div class="board-empty-icon"><MessageSquareHeart :size="19" /></div>
      <div class="board-empty-copy">
        <strong>还没有家庭留言</strong>
        <small>{{ loadError || "写下第一条留言，家人登录后左右滑动就能看到。" }}</small>
      </div>
      <IsleButton variant="glass" size="sm" @click="composerOpen = true">写第一条</IsleButton>
    </div>
  </section>
</template>
