** TO BE DONE ONLY ON THE USERS ORDER **

1. Post processing shaders (CRT Royal)
2. Performance optimization
3. When entering the settings from the main menu, use the regular menu sound.
   Only use the pause sound when pressing start in the game.
   Also, intering and exiting the advanced settings menu from the main menu
   shall trigger the same fade in/fade out effect. When pressing pause in the
   game there shall be no fade in/fade out effect.
4. In "non-original" gameplay, remove all the pause/load time
5. Rework the button configuration. We need a submenu in Advanced Settings specifically
   for this called Input configuration which would show something like:
------------------------------------------------------------------
               PLAYER 1   PLAYER 2   PLAYER 3   PLAYER 4
INPUT METHOD   KEYB.      GAMEPAD 1  GAMEPAD 2  KEYB.

CONFIGURATION
   UP          UP                               UP         
   DOWN        DOWN                             DOWN       
   LEFT        LEFT                             LEFT       
   RUGHT       RIGHT                            RIGHT
   A           Z          A          A          Z          
   B           X          B          B          X          
   C           C          C          C          C          
   START       ENTER      START      START      ENTER      

AUTOFIRE  ON/OFF
EXIT
------------------------------------------------------------------
   When a player select a gamepad, the player that used to have the gamepad now
   automatically switch to keyboard.
   Gamepads are detected automatically and dynamically. Whenever a new gamepad
   is connected during the game, a message is displayed for a while
   (GAMEPAD 2 CONNECTED) and disappear with a fade out effect. If a gamepad is
   connected in the input control menu, then it becomes available for selection.
   The input controls configuration is only meaningful for local players. Remote
   players deal with their own configuration.
   With this the Advanced Settings is a little revampled:
------------------------------------------------------------------
  INPUT CONFIGURATION...
  SOUND         ON
  VOLUME        50
  WINDOW SCALE  3
  FULL SCREEN   OFF

  LIVES         5
  CONTINUES     2 (<- 0 means no continue option)
  FRIENDLY HIT  ON

  DEFAULTS
  SAVE AND EXIT
  EXIT WITHOUT SAVING
------------------------------------------------------------------

6. Add the possibilty to play with an AI as a regular player.
   The AI can be assigned any player (1, 2, 3 or 4).
   It can play in regular games or network games.
   The AI strength must depend on the difficulty level.
   There is already a weak form of AI for testing that can be built upon.
   This would be available only in non-original version.
7. Allow human players to play bad guys and bosses
   In non-original game, in the character selects the user can press right when on
   blaze and the character select will scroll to the right discovering a new choice.
   The choice will show the same layout as for a regular character but the:
   i.   The id picture is the picture of a bad guy (is there one in the game ROM? if
        not generate for the Galsia)
   ii.  Instead of the name, we have "BAD GUYS"
   iii. There will be no indication of POWER, JUMP or SPEED (leave that place empty)
   iv.  Show a Galsia performing his combo (it probably does not have a combo just
        a punch is fine)
   If one player (local or remote) select the bad guys, then the game is played in
   bad guys mode. In bad guys mode the screen will be extended on each side. It will
   be completely black. It won't change a thing for the players who chose a regular
   character, but this is where the bad guys player(s) will be able to:
    - Pick their next character to play
    - Retreat if they want to. The black space should be just enough for no regular
      character being able to land a hit when a bad guy is far enough in it.
   The selection will be done as follows:
    - The bad guy characters that are supposed to be spawn in the next moment
      (say 5 seconds) will appear, immobile, in these black space. A yellow arrow at
      above their sprite will represent the selection.
    - If the bad guy player press any key, it means it selected the character and
      as soon as it is spawn, it will have control over it. As soon as his characters
      dies, it will have the opportunity to select the next bad guy to be spawn.
    - If the bad guy player does nothing, the bad guy character is spawn with the
      regular AI.
    - If multiple bad guys are supposed to appear. The bad guy player can change the
      selection with the arrow key to move the yellow arrow selection.
    Note that these bad guys are not necessarily Galsias. They will be the scripted
    bad guy (or gal) that are supposed to be appear in the level. This includes
    the boss.
8. Network workflow
   The host is either: the native server or the first connected to the headless server.

  # Host
  1 PLAYER
    Character select
  2 PLAYERS
    Character select
  NETWORK PLAY
    1 LOCAL PLAYER
      <Network option screen>
    2 LOCAL PLAYERS
      <Network option screen>
    3 LOCAL PLAYERS
      <Network option screen>
    4 LOCAL PLAYERS
      <Network option screen>

      Network option screen
        Local Area Game (localhost) /  Internet Game (0.0.0.0)
        NB players  2 3 (4 only if duplicate characters allowed)
        Allow observers  Yes/No
        Allow duplicate characters Yes/No
        Start
  OPTIONS
    <as of today with the ADVANCED SETTINGS... entry> (use ... to notify a sub menu)

  At the bottom left you can see who is connected:
  Bob (Menu)
  Alice (Observing)
  Local (Player 2)

  When the host pause it display the Advanced Settings with an additional entry at the end: Network settings:
  In-game Network Settings
      NB players  2 3 (4 only if duplicate characters allowed) <- Can only increase or decrease if no players are connected
  	Back    

  # Client
  ENTER YOUR NAME (Three characters only)
    JOIN (grayed out when host has not started the game)
      1 PLAYER
        Character select (other players selection visible)
      2 PLAYERS
        Character select (other players selection visible)
      3 PLAYERS
        Character select (other players selection visible)
      4 PLAYERS
        Character select (other players selection visible)
    OBSERVE
      See host screen
    OPTIONS
      <as of today with the ADVANCED SETTINGS... entry> (use ... to notify a sub menu)

  As long as player slots are available, players can join (by exiting observation)

  When more than 2 players are allowed in the party, the top in-game bar must be redesigned.
  The score is removed and the energy bar replaced it. Below the count of police and lives:

  BOB - PIx2
  [****  ]x2 

  PI means Police Icon which needs to be redesign to be place on one line.

  The last screen (with Mister X) only Player 1 and Player 2 get a choice and everything plays
  as if two players until Mr X rise from his chair and the remaining players enters the scene.

  # Disconnection

  When the host disconnect, the game is lost and the players are sent back to their main menu.

  When a client disconnect, the game stop with "PLAYER X DISCONNECTED (WAIT FOR 5 SEC)".
  The seconds decrease and either:
    - the client reconnect the game is unpaused
    - the client does not reconnect and the game is unpaused with the player characters
    	dying and not coming back (the client can rejoin later)

9. The management of gamepad is not great to me. First in the way we identify
   them: GAMEPAD 1. Imaging GAMEPAD A was connected on the game and identified
   as GAMEPAD 1. The game is shutdown, GAMEPAD A is disconnected and GAMEPAD B
   is connected. Launch the game, it will identify GAMEPAD B as GAMEPAD 1. But
   the layout button might be completely different though. There are various
   ways to identify a gamepad. It's vendorid/deviceid which is associated with
   a description string and the GUID (which I assume is unique per gamepad).
   In the input configuration menu, I imagine another submenu (GAMEPAD
   LSIT...) which would list all the gamepad that has been connected before
   and their description:
------------------------------------------------------------------
   GAMEPAD LIST

   GAMEPAD 1 Sega Corp. 6B controller
  >GAMEPAD 2 8BitDo 8BitDo Receiver

   PRESS DEL/B TO DISCONNECT
------------------------------------------------------------------
   The connected gamepad are highlighted.
   The unconnected gamepad are grayed out.
   The "selected" gamepad is shown with the arrow and pressing DEL remove the
   gamepad from the list. Only unconnected gamepad can be deleted so the
   message "PRESS DEL/B TO DISCONNECT" only appear in this case.
   Their label (GAMEPAD 1) are permanent. If only the 8bitdo received is
   connected, then it's identified as GAMEPAD 2 and get reassigned to however is
   was initialy reassigned with the same key bindings