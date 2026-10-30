// Browser module: 手机操控三档权限下拉（输入框下方，和「完全权限」同款交互）
window.__ModuleLoader__.load({
  id: 'dsh-phone-use',
  factory: (require) => {
    const React = require('react')
    const h = React.createElement
    const primitives = require('@deepseek-ai/dsh-client-ui-primitives')

    // ---------------------------------------------------------------------
    // 三档：full / auto / ask，按会话独立保存
    // ---------------------------------------------------------------------
    const LEVELS = [
      { value: 'full', label: '完全权限', glyph: '●', hint: '不拦截任何动作' },
      { value: 'auto', label: '自动确认', glyph: '◐', hint: '危险操作需确认' },
      { value: 'ask', label: '每次询问', glyph: '○', hint: '任何写操作都要确认' },
    ]

    const STORE_PREFIX = 'dsh-phone-use:permission:'

    function readLevel(sessionId) {
      try {
        const v = window.localStorage.getItem(STORE_PREFIX + (sessionId || 'default'))
        if (v === 'full' || v === 'auto' || v === 'ask') return v
      } catch (e) {}
      return 'auto'
    }

    function writeLevel(sessionId, value) {
      try {
        window.localStorage.setItem(STORE_PREFIX + (sessionId || 'default'), value)
        window.dispatchEvent(
          new CustomEvent('dsh-phone-use:permission-changed', {
            detail: { sessionId: sessionId, value: value },
          }),
        )
      } catch (e) {}
    }

    function labelOf(value) {
      const found = LEVELS.filter(function (x) {
        return x.value === value
      })[0]
      return found ? found.label : '自动确认'
    }

    function PermissionSelect(props) {
      const sessionId = props && props.sessionId
      const stLevel = React.useState(function () {
        return readLevel(sessionId)
      })
      const level = stLevel[0]
      const setLevel = stLevel[1]
      const stOpen = React.useState(false)
      const open = stOpen[0]
      const setOpen = stOpen[1]

      React.useEffect(
        function () {
          setLevel(readLevel(sessionId))
        },
        [sessionId],
      )

      const items = LEVELS.map(function (lv) {
        return {
          id: lv.value,
          label: lv.glyph + ' ' + lv.label,
          description: lv.hint,
        }
      })

      function choose(id) {
        setLevel(id)
        writeLevel(sessionId, id)
        setOpen(false)
      }

      const trigger = h(
        'button',
        {
          type: 'button',
          title: '手机使用权限（仅本会话生效）',
          onClick: function () {
            setOpen(!open)
          },
          style: {
            display: 'inline-flex',
            alignItems: 'center',
            gap: '4px',
            border: 'none',
            background: 'transparent',
            color: 'inherit',
            cursor: 'pointer',
            font: 'inherit',
            fontSize: '13px',
            padding: '2px 6px',
            borderRadius: '6px',
            whiteSpace: 'nowrap',
          },
        },
        h('span', { style: { opacity: 0.65 }, children: '手机权限' }),
        h('span', { children: labelOf(level) }),
        h('span', {
          style: {
            display: 'inline-flex',
            transform: open ? 'rotate(180deg)' : 'none',
            transition: 'transform 120ms ease',
            opacity: 0.7,
          },
          children: h(primitives.IconChevronDownOutlineRegular, {}),
        }),
      )

      const menu = h(primitives.Menu, {
        open: open,
        items: items,
        selectedId: level,
        onSelect: choose,
        onClose: function () {
          setOpen(false)
        },
        side: 'top',
        portal: true,
        anchor: trigger,
      })

      // 输入框右下角那一排：紧凑单一下拉，标题用 title 提示，不占横向空间
      return h(
        'div',
        {
          style: {
            display: 'inline-flex',
            alignItems: 'center',
          },
        },
        menu,
      )
    }

    // ---------------------------------------------------------------------
    // 注册：和 dsh-computer-use-win 一致
    // ---------------------------------------------------------------------
    function apply(ctx) {
      ctx.slots.inject('conversation.input.right', function () {
        return ctx.slots.register(
          {
            name: 'conversation.input.right',
            id: 'phone-use-permission',
            order: 30,
            inject: function (sessionId) {
              return { sessionId: sessionId }
            },
          },
          PermissionSelect,
        )
      })
    }

    return { apply: apply, inject: ['slots'] }
  },
})
