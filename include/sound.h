/** Layer 3 -- tiny UI feedback sounds (menu move/select, test pass/
 * fail). Pure GBC APU register writes (channel 1 square wave only),
 * no tracker/soundfont dependency. Each call blocks for a handful of
 * VBlanks (the same vsync()-loop style already used for serial
 * timeouts elsewhere in this project) and returns once the sound has
 * finished playing -- short enough (a few frames) that this doesn't
 * make the UI feel unresponsive.
 */
#ifndef SOUND_H
#define SOUND_H

/** Enables the APU and sets a sensible master volume/panning. Call
 * once at startup, after serial_hw_init(). */
void sound_init(void);

/** Short high blip -- menu cursor move / item chosen. */
void sound_select(void);

/** Short low buzz -- a test failed. */
void sound_error(void);

/** Two short ascending tones -- a test passed. */
void sound_success(void);

#endif /* SOUND_H */
