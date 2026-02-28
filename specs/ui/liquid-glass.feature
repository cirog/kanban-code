Feature: Liquid Glass Native Design
  As a macOS user
  I want Kanban to use Apple's liquid glass design language
  So that it feels like a premium native app, not an Electron wrapper

  Background:
    Given the Kanban application is running on macOS

  # ── Window and Chrome ──

  Scenario: Native macOS window
    When the app launches
    Then it should use a native macOS window
    And the title bar should integrate with the liquid glass style
    And the window should support:
      | Feature            | Description                          |
      | Full screen        | Native macOS full screen mode        |
      | Split view         | macOS split screen support           |
      | Resize             | Smooth resize with content reflow    |
      | Minimize/maximize  | Standard window controls             |

  Scenario: Liquid glass materials
    Given the macOS version supports liquid glass (macOS 26+)
    Then the UI should use glass material effects for:
      | Element            | Effect                              |
      | Column headers     | Frosted glass with blur             |
      | Card surfaces      | Subtle glass overlay                |
      | Search overlay     | Blurred background                  |
      | Sidebar            | Glass panel                         |
      | Dialogs            | Frosted glass modal                 |

  Scenario: Graceful degradation on older macOS
    Given the macOS version doesn't support liquid glass
    Then the app should fall back to a clean native design
    And all functionality should work identically
    And the design should still look polished

  # ── Color and Theming ──

  Scenario: Automatic dark/light mode
    When the system appearance changes
    Then the app should instantly adapt
    And colors should follow system accent color
    And the glass effect should work in both modes

  Scenario: High contrast mode support
    Given macOS high contrast is enabled
    Then all card text should remain readable
    And status badges should maintain sufficient contrast
    And interactive elements should have clear boundaries

  # ── Typography ──

  Scenario: System font usage
    Then the app should use SF Pro (system font) throughout
    And monospace elements (terminal, code) should use SF Mono
    And font sizes should respect macOS Dynamic Type settings

  # ── Animations ──

  Scenario: Card movement animations
    When a card moves between columns (automatic or drag)
    Then the transition should be smooth (spring animation)
    And the card should animate from source to destination
    And other cards should reflow smoothly

  Scenario: Column expand/collapse animation
    When the "All Sessions" column is toggled
    Then it should expand/collapse with a smooth animation
    And neighboring columns should resize fluidly

  Scenario: Search overlay animation
    When I press Cmd+K
    Then the search overlay should fade in with blur
    And Escape should animate it out
    And the animation should feel instant (<200ms)

  # ── Native Interactions ──

  Scenario: Right-click context menus
    When I right-click a session card
    Then a native macOS context menu should appear
    And it should include:
      | Item             |
      | Open terminal    |
      | Fork             |
      | Checkpoint       |
      | Rename           |
      | Copy resume cmd  |
      | Open PR          |
      | Archive          |

  Scenario: Keyboard navigation
    Then the app should support:
      | Shortcut   | Action                    |
      | Cmd+K      | Open search               |
      | Cmd+N      | New manual task            |
      | Cmd+,      | Open settings             |
      | Cmd+1-6    | Switch to column N        |
      | Tab        | Navigate between columns  |
      | Arrow keys | Navigate within columns   |
      | Enter      | Open selected card        |
      | Escape     | Close panel/overlay       |

  Scenario: Touch Bar support (if applicable)
    Given the Mac has a Touch Bar
    Then it should show context-relevant controls
    And when viewing a card: Resume, Fork, Open PR buttons
