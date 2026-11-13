// SculptDefs : les SynthDefs de sculpt, sans état.
SculptDefs {
	// nombre de bandes de RING, comme le S4
	classvar <ringBands = 48;
	// Companding du crush de DEFORM : les niveaux sont écrasés avant d'être
	// quantifiés, puis rétablis. Valeur choisie à l'oreille le 2026-11-13.
	classvar <crushLaw = 0.32;

	// La réverbe de VAST, en échantillons à 48 kHz.
	// Les huit lignes et leurs allpass sont tous des nombres premiers : des
	// longueurs commensurables feraient coïncider leurs modes, ce qui
	// s'entend comme une résonance. Les signes d'entrée et de sortie sont
	// tirés une fois pour toutes ; une ligne qui entre et sort toujours du
	// même côté excite toujours les mêmes modes.
	classvar <revLines = #[967, 1361, 1777, 2251, 2833, 3499, 4273, 5147];
	classvar <revAp;
	classvar <revDiff = #[211, 397, 653, 1021];
	classvar <revB = #[1, 1, -1, 1, -1, -1, -1, -1];
	classvar <revCL = #[1, 1, 1, -1, 1, -1, -1, 1];
	classvar <revCR = #[1, 1, -1, -1, 1, 1, -1, -1];
	// Modulation des longueurs. C'est elle qui défait les résonances fixes :
	// mesurée, l'ondulation du spectre de la queue passe de 12 dB sans elle
	// à 6 dB à cette profondeur, pour 5,4 dB sur un bruit idéal. Plus
	// profond, la queue se met à chanter.
	classvar <revMod = 0.08;
	classvar <revModHz = 2;
	// Amortissement : l'aigu doit s'éteindre plus vite que le grave, comme
	// dans une vraie salle. Sans ce filtre il durait plus longtemps.
	classvar <revDamp = 5000;

	*initClass {
		revAp = [
			#[293, 421, 547, 701, 877, 1087, 1327, 1597],
			#[181, 257, 337, 431, 541, 661, 811, 977],
			#[113, 163, 211, 271, 347, 419, 509, 617]
		];
	}

	// Matrice de Hadamard appliquée par papillon : chaque sortie reçoit
	// toutes les entrées, avec autant de plus que de moins, en 3 étages de
	// 8 additions au lieu des 64 multiplications d'une matrice écrite à plat.
	*hadamard { |arr|
		var y = arr, size = arr.size, step = 1;
		while { step < size } {
			var z = Array.newClear(size);
			size.do { |i|
				if((i bitAnd: step) == 0) {
					z[i] = y[i] + y[i + step];
					z[i + step] = y[i] - y[i + step];
				};
			};
			y = z;
			step = step * 2;
		};
		^y * size.sqrt.reciprocal;
	}

	*add {
		// Lecteur de sample : lit tout le buffer en boucle.
		//   play  : 1 lecture (fondu de 1 ms, pour garder l'attaque du sample),
		//           0 arrêt (fondu de 10 ms) ; t_reset repart du début
		//   speed : vitesse (1 = normale), corrigée du taux du fichier
		// Un fondu de 5 ms à chaque bout évite le clic au raccord de boucle.
		// La position (0..1) part vers sclang 30 fois par seconde.
		SynthDef(\sculpt_player, { |out, buf, play = 0, speed = 1, level = 1, t_reset = 0|
			var frames = BufFrames.kr(buf);
			var gate = play > 0;
			var rate = BufRateScale.kr(buf) * speed * gate;
			var phase = Phasor.ar(T2A.ar(t_reset), rate, 0, frames, 0);
			var sig = BufRd.ar(2, buf, phase, 1, 4);
			var edge = (min(phase, frames - phase) / (0.005 * SampleRate.ir)).clip(0, 1);
			var amp = LagUD.kr(gate, 0.001, 0.01) * Lag.kr(level, 0.05);
			SendReply.kr(Impulse.kr(30), '/sculpt/pos', A2K.kr(phase) / frames);
			Out.ar(out, sig * edge * amp);
		}).add;

		// MOSAIC : granulaire sur les 4 dernières secondes du flux.
		// Le flux est enregistré en boucle dans bufL / bufR (un buffer mono
		// par côté), et des grains y sont relus.
		//   pitch    : hauteur des grains, en demi-tons
		//   rate     : cadence, en grains par seconde
		//   size     : durée d'un grain, en secondes
		//   contour  : forme du grain, -1 percussif .. 0 cloche .. +1 montée
		//   scan     : 0..1. scanMode 0 : retard derrière l'écriture (0..3,5 s) ;
		//              scanMode 1 : position fixe dans le buffer
		//   spray    : dispersion aléatoire de la position, tirée à part pour
		//              chaque côté, ce qui élargit la stéréo
		//   feedback : part de la sortie des grains réinjectée dans le buffer
		//   wet      : 0 direct seul .. 1 grains seuls
		//   lock     : 1 = le buffer n'est plus écrit
		//   bypass   : 1 = le direct seul (fondu de 20 ms)
		SynthDef(\sculpt_mosaic, { |bus, bufL, bufR, envBase, envSteps = 9, bypass = 0, lock = 0,
			pitch = 0, rate = 8, size = 0.15, contour = 0, scan = 0.1, scanMode = 0,
			spray = 0.1, feedback = 0, wet = 0.5|
			var in = In.ar(bus, 2);
			var sr = SampleRate.ir;
			var frames = BufFrames.kr(bufL);
			var bufDur = frames / sr;
			var run = 1 - lock;
			// la tête d'écriture : avance avec RecordBuf, s'arrête avec lui
			var wphase = Phasor.ar(0, run, 0, frames);
			var fb = LocalIn.ar(2);
			var ratio = pitch.midiratio;
			// au plus 48 grains à la fois par côté, pour borner le CPU
			var dur = min(size, 48 / rate);
			var trig = Impulse.ar(rate);
			// Un grain lu plus vite que l'écriture la rattraperait : le retard
			// minimal en tient compte. Le maximal laisse le grain finir avant
			// que l'écriture, qui a fait le tour, ne le rejoigne.
			var minD = (dur * max(ratio - 1, 0)) + 0.01;
			var maxD = bufDur - dur - 0.05;
			// SPRAY couvre tout ce que le buffer laisse disponible. La course
			// est élevée au carré : ses premiers degrés valent quelques
			// millisecondes, de quoi défaire l'addition en phase des grains,
			// et le haut de la course balaie le buffer entier.
			var sprayAmt = spray.squared;
			var scanD = (scan * 3.5).clip(minD, maxD);
			// en delay, l'étendue est ce qui reste derrière le point de scan :
			// au-delà, les grains s'entasseraient tous sur la borne
			var spreadDelay = (maxD - scanD) * sprayAmt;
			var spread = Select.kr(scanMode, [spreadDelay, bufDur * sprayAmt]);
			var env = envBase + ((contour + 1) * 0.5 * (envSteps - 1)).round;
			// Les grains se superposent : on ramène le niveau vers celui de
			// l'entrée. En général leurs ondes se mélangent au hasard, et le
			// niveau monte comme la racine de leur nombre (0,375 = puissance
			// moyenne d'une enveloppe). Mais sans dispersion et à hauteur 0, ils
			// relisent le même son en phase et s'additionnent pleinement (0,5 =
			// valeur moyenne d'une enveloppe). Entre les deux, la part en phase
			// dépend de l'étendue de SPRAY. Des grains clairsemés gardent leur
			// niveau.
			var n = rate * dur;
			// Ce qui décide, c'est l'étendue rapportée à la taille du grain :
			// des grains dispersés sur bien moins que leur propre durée lisent
			// presque le même segment et s'additionnent en phase. Le 45 est
			// mesuré au bruit rose. Un grain transposé se décorrèle tout seul.
			var inPhase = (1 + (45 * spread / dur)).reciprocal * (1 - pitch.abs).clip(0, 1);
			var norm = (((n * 0.375).sqrt * (1 - inPhase)) + (n * 0.5 * inPhase)).max(1).reciprocal;
			var grains = [bufL, bufR].collect { |b|
				var d = (scanD + (TRand.ar(0, 1, trig) * spreadDelay)).clip(minD, maxD);
				var posDelay = ((wphase / sr) - d) / bufDur;
				// en position, la lecture fait le tour du buffer : à fond,
				// SPRAY le couvre en entier sans se heurter à une borne
				var posFixed = scan + (TRand.ar(-0.5, 0.5, trig) * sprayAmt);
				var pos = Select.ar(K2A.ar(scanMode), [posDelay, posFixed]).wrap(0, 1);
				GrainBuf.ar(1, trig, dur, b, ratio, pos, 4, 0, env, 64);
			} * norm;
			var mix = Lag.kr(1 - bypass, 0.02);
			var w = Lag.kr(wet, 0.05);
			// à 100 %, la boucle rend 80 % de ce qu'elle reçoit
			var fbAmt = Lag.kr(feedback, 0.05) * 0.8;
			var out, rec;
			// Le retour est filtré : sous 50 Hz, les grains s'additionnent
			// toujours en phase et la boucle aurait un gain supérieur à 1.
			LocalOut.ar(HPF.ar(HPF.ar(grains, 50), 50));
			// Le retour passe par un limiteur à 0,3. Un feedback normal (gain
			// de boucle sous 1) ne l'atteint pas ; il ne retient que les cas où
			// la boucle résonne, par exemple à 100 % avec la hauteur décalée.
			// L'entrée, elle, est enregistrée telle quelle.
			rec = [bufL, bufR].collect { |b, i|
				var sig = in[i] + Limiter.ar(fb[i] * fbAmt, 0.3, 0.005);
				RecordBuf.ar(sig, b, run: run, loop: 1);
				sig;
			};
			out = (in * (1 - w)) + (grains * w);
			// Pour la visualisation : la tête d'écriture, et le niveau de ce
			// qui s'écrit sous elle. 32 messages par seconde, soit une colonne
			// d'écran par message pour un buffer de 4 s affiché sur 128 px.
			SendReply.kr(Impulse.kr(32), '/sculpt/mos',
				[A2K.kr(wphase) / frames, A2K.kr(Amplitude.ar(rec.sum * 0.5, 0.001, 0.02))]);
			ReplaceOut.ar(bus, (in * (1 - mix)) + (out * mix));
		}).add;

		// Sortie : copie le bus de la chaîne vers la sortie du norns.
		// sortie : un limiteur retient ce qui dépasserait la pleine échelle
		// (sample fort, level au-dessus de 100 %, effet ajouté au direct).
		// Sous le seuil il ne touche à rien. Il anticipe de 5 ms : c'est le
		// retard qu'il ajoute à toute la chaîne.
		// RING : un banc de 48 filtres résonnants.
		//
		// Le travail est coupé en deux synths. Celui-ci calcule les 48
		// triplets — fréquence, niveau, durée de résonance — et les dépose sur
		// un bus de contrôle ; le suivant fait le filtrage. Un seul graphe qui
		// ferait les deux dépasse ce que le serveur de norns accepte
		// (« exceeded number of interconnect buffers »), et deux graphes
		// moyens coûtent le même prix que le gros.
		//
		// Les bandes sont réparties à intervalle égal en octaves, de 40 Hz à
		// 16 kHz : 2,2 demi-tons de l'une à l'autre. À résonance courte elles
		// se recouvrent et rendent le signal tel quel ; en l'allongeant, elles
		// sonnent chacune à sa hauteur.
		//   cutoff : la fréquence où le profil bascule
		//   slope  : -1 passe-bas .. 0 passe-bande .. +1 passe-haut
		//   reso   : bosse du profil autour de cutoff
		//   decay  : durée de résonance des bandes (sa course est au carré)
		//   tilt   : incline cette durée entre graves et aigus
		//   tone   : pente générale du profil, graves contre aigus
		//   pitch  : transpose tout le banc, en demi-tons
		SynthDef(\sculpt_ring_shape, { |out, cutoff = 16000, reso = 0, decay = 0,
			pitch = 0, slope = -1, tone = 0, tilt = 0|
			var nb = ringBands;
			var base = Array.fill(nb, { |i| 40 * (2 ** (i * 8.64 / (nb - 1))) });
			var ratio = pitch.midiratio;
			// position de chaque bande par rapport à cutoff, en octaves
			var xs = base.collect { |f| f.log2 + (ratio / cutoff).log2 };
			var hiCut = (1 - slope) * 12;
			var loCut = (1 + slope) * 12;
			var ring = decay.squared * 4;
			var rings = xs.collect { |x| (ring * 2.pow(x * tilt * 0.5)) + 0.0015 };
			// Une bande qui sonne longtemps est aussi plus étroite : elle
			// reçoit moins et rend plus. Mesuré au bruit rose, le niveau monte
			// comme la durée de résonance à la puissance 0,34 ; on le reprend
			// ici, sinon monter DECAY ferait surtout monter le volume.
			var amps = xs.collect { |x, i|
				((x.max(0).neg * hiCut) + (x.min(0) * loCut) + (x * tone * 6)
					+ (reso * 18 * (x.squared * -5.5).exp)).dbamp
				* (0.0015 / rings[i]).pow(0.34);
			};
			Out.kr(out, base.collect { |f| f * ratio } ++ amps ++ rings);
		}).add;

		// Le filtrage lui-même : chaque côté traverse le banc.
		// DEFORM : distorsion en deux bandes, avec un bruit qui suit le signal.
		//
		// L'ordre interne est celui du S4 : NOISE, DRIVE, CRUSH, COMPRESS. Le
		// bruit s'ajoute avant le partage en deux bandes, puisqu'il suit le
		// signal entier ; le reste travaille sur chaque bande à part, ce qui
		// évite que les graves saturent tout le spectre.
		//   drive     : 0..1, de 1 à 50 fois avant l'écrêtage doux
		//   crush     : 0..1, selon crushMode 0 bits, 1 échantillonnage, 2 les deux
		//   comp      : 0..1, un seul bouton pour le seuil et le taux
		//   tilt      : -1..1, quelle bande part la première dans la saturation
		//   xover     : la fréquence qui sépare les deux bandes
		//   noise     : 0..1 ; noiseType 0 blanc, 1 rose, 2 dust
		//   noiseDecay: temps de descente du suiveur, en secondes
		//   noiseTone : fréquence du passe-bande posé sur le bruit
		SynthDef(\sculpt_deform, { |bus, wet = 0.5, bypass = 0, drive = 0, crush = 0,
			crushMode = 0, comp = 0, tilt = 0, xover = 650, noise = 0, noiseType = 1,
			noiseDecay = 0.2, noiseTone = 1200, gain = 1|
			var in = In.ar(bus, 2);
			var env = Amplitude.ar(in, 0.005, Lag.kr(noiseDecay, 0.05));
			var nz = [0, 1].collect { |c|
				BPF.ar(Select.ar(noiseType,
					[WhiteNoise.ar(1), PinkNoise.ar(1), Dust2.ar(3000)]), noiseTone, 1.5);
			};
			var noisy = in + (nz * env * Lag.kr(noise, 0.05) * 6);
			// L'écrêtage est ramené à l'échelle (il passe par 1 quel que soit le
			// gain d'attaque), puis mélangé au signal propre selon DRIVE :
			// à 0, l'étage laisse passer exactement ce qu'il reçoit.
			var dv = Lag.kr(drive, 0.05);
			var d = dv.linexp(0, 1, 1, 50);
			// Le crush compte en bits, de 12 à 4 : une échelle en bits répartit
			// l'effet sur toute la course, là où une échelle en pas d'arrondi
			// n'aurait rien donné avant la toute fin. 24 bits et la fréquence
			// d'échantillonnage du serveur reviennent à ne rien faire.
			var bits = 12 - (Lag.kr(crush, 0.05) * 8);
			var rate = Lag.kr(crush, 0.05).linexp(0, 1, 20000, 700);
			var bitsOn = Select.kr(crushMode, [bits, 24, bits]);
			var rateOn = Select.kr(crushMode, [SampleRate.ir, rate, rate]);
			// jitter : l'horloge d'échantillonnage n'est pas tout à fait stable
			var rateJit = rateOn * (1 + (LFNoise1.kr(30) * 0.03));
			var c = Lag.kr(comp, 0.05);
			var thr = 1 - (c * 0.95);
			var slope = 1 - (c * 0.8);
			// le rattrapage de niveau du compresseur, borné : sinon un seuil
			// très bas remonte tout le signal, y compris ce qu'il n'a pas touché
			var makeup = min(thr.pow((slope - 1) * 0.5), 1.6);
			var low = LPF.ar(noisy, Lag.kr(xover, 0.05));
			var bands = [low * (tilt * -6).dbamp, (noisy - low) * (tilt * 6).dbamp];
			var out = bands.collect { |b|
				// l'écrêtage remonte beaucoup les niveaux faibles : mesuré au
				// bruit rose, son gain suit le gain d'attaque à la puissance 0,75
				var sig = (b * (1 - dv)) + ((((b * d).tanh) / d.tanh) * dv * d.pow(-0.75));
				// Companding : on écrase les niveaux avant de quantifier et on
				// les rétablit après, pour que les sons faibles gardent de la
				// résolution. L'erreur devient alors proportionnelle au signal
				// au lieu d'être un plancher fixe — le grain des vieux
				// samplers, qui s'efface avec le son au lieu de rester sous lui.
				var q = Decimator.ar(sig.sign * sig.abs.pow(crushLaw), rateJit, bitsOn);
				sig = q.sign * q.abs.pow(crushLaw.reciprocal);
				Compander.ar(sig, sig, thr, 1, slope, 0.005, 0.12) * makeup;
			}.sum * gain;
			var w = Lag.kr(wet, 0.05);
			var mix = Lag.kr(1 - bypass, 0.02);
			var o = (in * (1 - w)) + (out * w);
			ReplaceOut.ar(bus, (in * (1 - mix)) + (o * mix));
		}).add;

		// Le gain remet le banc au niveau de l'entrée : mesuré au bruit rose,
		// 48 bandes larges qui se recouvrent sortaient 6 fois trop fort.
		SynthDef(\sculpt_ring, { |bus, ctl, wet = 0.5, bypass = 0, gain = 0.0133|
			var nb = ringBands;
			var in = In.ar(bus, 2);
			var p = In.kr(ctl, nb * 3);
			var out = [0, 1].collect { |c|
				DynKlank.ar(`[p[0..(nb - 1)], p[nb..((2 * nb) - 1)], p[(2 * nb)..]], in[c]);
			} * gain;
			var w = Lag.kr(wet, 0.05);
			var mix = Lag.kr(1 - bypass, 0.02);
			var o = (in * (1 - w)) + (out * w);
			ReplaceOut.ar(bus, (in * (1 - mix)) + (o * mix));
		}).add;

		// VAST : un delay et une réverbe, chacun avec son dosage.
		//
		// Le signal traverse le delay, puis la réverbe. Les deux boucles de
		// retour passent par le même filtre (TONE), comme sur le S4.
		//
		// La réverbe est un réseau de retards bouclés : 8 lignes de longueurs
		// premières entre elles, mélangées à chaque tour par une matrice de
		// Hadamard, qui conserve l'énergie et répartit chaque écho sur toutes
		// les lignes. Quatre allpass en entrée épaississent tout de suite ce
		// que le réseau mettrait plusieurs tours à densifier. Les longueurs
		// sont modulées lentement, ce qui casse les résonances fixes.
		//
		// Fait maison plutôt qu'une réverbe toute faite parce que CLEAR et
		// FREEZE demandent d'atteindre les boucles, ce qu'une boîte fermée
		// comme JPverb ne permet pas — et parce que c'est six fois moins cher.
		//   time     : retard du delay, en secondes
		//   feedback : 0..1 du delay
		//   spread   : selon spreadMode 0 décalage L/R, 1 ping-pong, 2 diffusion
		//   tone     : -1 passe-bas .. 0 rien .. +1 passe-haut, dans les boucles
		//   size     : longueur des lignes de la réverbe
		//   decay    : durée de sa queue
		//   freeze   : 1 = les boucles se referment sur elles-mêmes
		//   t_clear  : vide les deux
		SynthDef(\sculpt_vast, { |bus, dlyMix = 0, revMix = 0, time = 0.375,
			feedback = 0.4, spread = 0, spreadMode = 0, tone = 0, size = 0.5,
			decay = 0.5, freeze = 0, t_clear = 0, bypass = 0|
			var n = 8;
			var sr = SampleRate.ir;
			var in = In.ar(bus, 2);
			var frz = Lag.kr(freeze, 0.05);
			// le vidage coupe les retours le temps que les lignes se traversent
			var clear = 1 - Trig.kr(t_clear, max(time, 0.3));
			// TONE : un seul réglage, passe-bas d'un côté, passe-haut de l'autre
			var t = Lag.kr(tone, 0.05);
			var lpf = 18000 * (0.012 ** max(t.neg, 0));
			var hpf = 20 * (150 ** max(t, 0));
			var colour = { |sig| LPF.ar(HPF.ar(sig, hpf), lpf) };
			// une seule boucle pour tout le synth : 2 voies pour le delay,
			// 8 pour la réverbe
			var loop = LocalIn.ar(n + 2) * clear;
			var dFb = loop[0..1], rFb = loop[2..(n + 1)];
			var sp = Lag.kr(spread, 0.05);
			// le mode choisit ce qui s'applique, par fondu plutôt que par
			// aiguillage : les trois cohabitent dans le même graphe
			var ppAmt = Select.kr(spreadMode, [0, 1, 0]) * sp;
			var dfAmt = Select.kr(spreadMode, [0, 0, 1]) * sp;
			var offset = Select.kr(spreadMode, [1, 0, 0]) * sp;
			var tm = Lag.kr(time, 0.1);
			var dIn = (in * (1 - frz)) + dFb;
			var dly = [DelayC.ar(dIn[0], 2.1, tm),
				DelayC.ar(dIn[1], 2.1, tm * (1 + (offset * 0.4)))];
			var dfs = dly;
			var dOut, dBack, rIn, rLines, rMix, rOut, out, mixG, t60, ref;
			4.do { |i|
				dfs = AllpassC.ar(dfs, 0.08, [0.0131, 0.0217, 0.0353, 0.0471][i]
					* [1, 1.17], 0.3);
			};
			dOut = (dly * (1 - dfAmt)) + (dfs * dfAmt);
			dOut = colour.(dOut);
			// ping-pong : ce qui revient repart de l'autre côté
			dBack = ((dOut * (1 - ppAmt)) + (dOut.reverse * ppAmt))
				* ((Lag.kr(feedback, 0.05) * (1 - frz)) + frz);
			out = (in * (1 - dlyMix)) + (dOut * dlyMix);

			// la réverbe
			// Quatre allpass courts épaississent l'entrée. Leur sortie ne va
			// qu'au réseau : un allpass ne perd pas d'énergie, il ne fait
			// qu'étaler l'impulsion, et l'écouter directement donne une
			// traîne métallique d'une seconde qui couvre la vraie queue.
			rIn = out * (1 - frz) * 0.4;
			SculptDefs.revDiff.do { |d|
				rIn = AllpassC.ar(rIn, 0.04, d / sr * [1, 1.13], 0.5);
			};
			t60 = Lag.kr(decay, 0.2).linexp(0, 1, 0.35, 9);
			ref = Lag.kr(size, 0.2).linexp(0, 1, 0.5, 1.8);
			// Chaque ligne porte trois allpass : ils allongent la boucle et
			// densifient les échos sans ajouter de mode qui sonne. La longueur
			// totale de la boucle décide du nombre de modes ; trop courte, ils
			// s'espacent et s'entendent un par un.
			rLines = Array.fill(n, { |i|
				var d = DelayC.ar((rIn[i % 2] * SculptDefs.revB[i]) + rFb[i], 0.4,
					SculptDefs.revLines[i] / sr * ref
						* (1 + (LFNoise2.kr(SculptDefs.revModHz + (i * 0.07))
							* SculptDefs.revMod)));
				SculptDefs.revAp.do { |a, k|
					d = AllpassC.ar(d, 0.14, a[i] / sr * ref
						* (1 + (LFNoise2.kr(SculptDefs.revModHz + (i * 0.05) + (k * 0.3))
							* SculptDefs.revMod)), 0.5);
				};
				d;
			});
			rMix = SculptDefs.hadamard(rLines);
			// TONE, et l'amortissement qui fait mourir l'aigu le premier
			rMix = LPF.ar(HPF.ar(rMix, hpf), min(lpf, SculptDefs.revDamp));
			// Le gain vise le même temps de descente pour toutes les lignes :
			// une ligne longue repasse moins souvent, elle doit donc perdre
			// moins à chaque tour. Gelée, la boucle ne perd plus rien.
			rOut = rMix * SculptDefs.revLines.collect { |len, i|
				var eff = (len + SculptDefs.revAp.sum { |a| a[i] }) / sr * ref;
				((10 ** (-3 * eff / t60)) * (1 - frz)) + frz;
			};
			// un seul retour pour tout le synth : les deux voies du delay,
			// puis les huit lignes de la réverbe
			LocalOut.ar(dBack ++ rOut);
			// Les deux sorties prennent les huit lignes avec des signes
			// différents : chacune entend tout le réseau, et pas la même chose.
			out = (out * (1 - revMix))
				+ ([Mix(rLines * SculptDefs.revCL), Mix(rLines * SculptDefs.revCR)]
					* 0.7 * revMix);

			mixG = Lag.kr(1 - bypass, 0.02);
			ReplaceOut.ar(bus, (in * (1 - mixG)) + (out * mixG));
		}).add;

		SynthDef(\sculpt_out, { |in, out|
			Out.ar(out, Limiter.ar(In.ar(in, 2), 0.99, 0.005));
		}).add;
	}
}
