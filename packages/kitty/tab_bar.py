from kitty.fast_data_types import Screen
from kitty.rgb import alpha_blend, color_from_int
from kitty.tab_bar import DrawData, ExtraData, TabBarData, as_rgb, draw_tab_with_slant


TAB_BACKGROUNDS = (
    0x89B4FA,
    0xA6E3A1,
    0xFAB387,
    0xCBA6F7,
    0xF9E2AF,
    0x94E2D5,
    0xF38BA8,
    0x89DCEB,
)


def draw_tab(
    draw_data: DrawData,
    screen: Screen,
    tab: TabBarData,
    before: int,
    max_tab_length: int,
    index: int,
    is_last: bool,
    extra_data: ExtraData,
) -> int:
    # Tab IDs keep colors stable when tabs are reordered or closed.
    background = TAB_BACKGROUNDS[(tab.tab_id - 1) % len(TAB_BACKGROUNDS)]
    if not tab.is_active:
        background = int(
            alpha_blend(color_from_int(background), draw_data.default_bg, 0.2)
        )

    screen.cursor.bg = as_rgb(background)
    return draw_tab_with_slant(
        draw_data, screen, tab, before, max_tab_length, index, is_last, extra_data
    )
