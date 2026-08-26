--[[ Tower Creator Kit V5.35
OK BEFORE YOU DO ANYTHING, PLEASE READ THIS SO YOU TOWER CAN HAVE A HIGHER CHANCE OF YOUR TOWER BEING ACCEPTED.
Hopefully you know how to use studio and know all of its hotkeys and such.

CREDITS:
- Jukereise, for the keys, buttons, and speed boosters
- Knighterisk, for fixing the pushing platform trampolines and the falling platforms
- funwolf7, for the noclip tool provided in this kit
- Other various people, for a few items included in the kit set

NEW CHANGES FOR V5.3:
- Made this script up-to-date.
- Fixed the issues with v5.2 that came from it starting with v5 instead of v5.1.
- Conveyor beams now automatically move at the same speed as the conveyor.
- Finally replaced the noclip tool with the one made by funwolf7.
- The indicated beat blocks are now optional.
- Pushbox script has been simplified and you can now load module scripts inside boxes.
- Script repositories are no longer default as they were complicated for beginners.
- Memory platforms removed :)

NEW CHANGES FOR V5.35:
- Fixed jump pads so that they don't affect accessories and other parts.
- Along with this, added a way to make them pushbox/player specific.
- Shoving platforms now use a "servo" instead of a "motor", making them far less buggy.
- Reverted the button script since it exploded when we put towers with it in the game.
- Added a "color specific" option to buttons (this is for pushboxes and balloons).
- Reworked the jump boost pad so that it doesn't lag your tower to death.
- You can also make these button-activated now.
- Added the player module from the game to the kit (FINALLY).

NEW CHANGES FOR v5.4 (surprisingly quite a big update):
- New familiar client objects: Disappearing Platforms, Swings, Speed Boost Pads, Seats, Trip Parts and Balloon Destroyers
- Turret activated morphers and buttons
- Distance Anchoring Folder for laggy towers
- Tweaks to scripts that automatically check some StarterPlayer values (the kit will also no longer break when you have a double client object value)
- Conveyors are now client objects and can work unanchored
- Pushbox spawners have a debounce in order to prevent crashes and bugs
- Speed Boosters and Jump Boosters are client objects now, they also have an instant value if you don't like the tweening effect
- Buttons have a "HideGUI" option now if you're using timed buttons but don't want the player to see them
- Buttons now affect beams and trails
- Button platforms can now be given a "SetTransparency" value to configure the transparency of a button platform when it is on (useful for windows and such)
- Button activated bugfixes for elevators, teleporters, and turrets
- Button deactivators can now support pushboxes
- Added the flip script along with a flip part in the kit
- Moving platforms have been reworked to use attachment constraints instead of body movers (note that this change allows you to make rotating moving platforms)
- Any part can now be given an "IsBox" value in order to be treated like a pushbox by other objects, useful for parts that can't be renamed without breaking
- Removed herobrine

NEW CHANGES FOR v5.5:
- New client objects: Swing Dismounters, Music Zone Editors, Sound Players, Bullet Velocity Changers, Lighting Effect Changers
- Button / button deactivator rework (this includes many new settings)
- Pushbox spawn buttons can now be activated by other objects
- Slight morpher changes
- Jump pad redesign
- Turrets now shoot preset bullets and have options to ignore players and/or parts
- New "KeepVelocity" and "AllowJumpDismount" settings for swings
- Elevator "MaxForce" setting
- New "KeepVelocity" and "TransitionTime" settings for teleporters
- Removed herobrine

Also, before you continue, read the tower building rules in the discord (you should find them if you scroll up in #tower-submissions)

KEEP EVERYTHING IN THEIR CORRECT DIRECTORIES (PLEASE)

NOTE THAT CLIENT OBJECTS WILL NOT WORK UNLESS IN THE DESIGNATED "ClientSidedObjects" FOLDER

Obstacle Info:

Spinning Platform: Spins on an axis. You can adjust the speed in the anchor part's CylindricalConstraint(AngularVelocity)
Spinning Killbrick: Same as spinning platform, but hurts you on touch.
Beginner Spinning Weld Platform: An invisible, uncollidable spinning platform with parts that are connected to it by weld constraints. They are there in case the builder doesn't know the magic of weld constraints yet hence the "beginner".
Rope Platform: A platform hanging on multiple ropes.
Pushing Platform: A platform with a wall on it that moves players along if they push against the X. You can configure it's max distance by changing the "UpperLimit" in its prismatic constraint.
Pushing Platform Trampoline: A downwards pushing platform that will fling the player upwards when it reaches its lowest point.
Loose Platform: A loose platform
Tilting Platform: A platform that tilts on a certain axis.
Falling Platform: A platform that falls down as you land on it.

Speed Booster: Boosts the player's walk speed for a certain duration of time, you can also set the boost length to "inf" to make it permanent.
Jump Booster: Boosts the player's jump power for a certain duration of time, you can also set the boost length to "inf" to make it permanent.
Speed Remover: Removes a player's speed boost, if they have one.
Jump Remover: Removes a player's jump boost, if they have one.
Lighting Changer: Sets the lighting to whatever is in the "Configuration" script.
Beat Blocks: Changes collision and transparency every "beat", which is the "ToggleTime" value. They come in groups, so you can make them change in a specific order.

Moving Platform: A platform that repeatedly moves between 2 points.
Button: Activates all platforms named ButtonActivatedPlatform and is the exact same color as the button. Can be configured to support various objects.
Button Deactivator: When touched, deactivates every button the player has pressed so far. Can also be configured to only deactivate a specific button.
Morpher: A button that smoothly transitions the "Morph" part into the "NewMorph" parts that you assign to it. Can also be configured to support players and/or pushboxes.
Zipline: When activated, the player starts going across the rope on a zipline. Configure the length with UpperLimit on the prismatic constraint.
Turret: Constantly shoots bullets that may or may not be lethal to the player.

Balloon: Creates a balloon that floats in the air for a set time/height before it pops (or until the player jumps, if you have CannotDismount set to true).
Shoving Platform: Erratically moves in 2 directions, if the player is in the way, they get yeeted.
Teleporters: Teleports the player one way on touch. You can configure it to remove button progress. Great for reverse towers on the easy side!
Elevators: Carries the player in a certain direction while they are in its vicinity.
Key: If the player collects it, they will be able to open the Key Door with the same KeyID as the Key. You can also design the key to be whatever you want, just make sure it all stays inside the "KeyHitbox" part.
Key Door: Will open when the player touches it if they have the Key that matches the KeyID of it.

Pushbox Spawner: Spawns a pushbox with the press of the button. You can also make it spawn an entire model of parts. However, if you want any parts in this model to stay anchored, add a boolvalue named "BoxAnchor" to it.
Pushbox Destroyer: Destroys any pushboxes it touches, can be color specific.
Pushbox Color Changer: Changes the color of any pushbox it touches. Can also be configured to support pushboxes and/or turret bullets.

Ok, have fun.
--]]