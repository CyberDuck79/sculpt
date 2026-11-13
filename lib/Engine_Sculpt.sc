// Engine_Sculpt : le moteur de sculpt.
//
//   source (lecteur de sample) ─► srcBus ─► MOSAIC ─► [ RING, DEFORM, VAST à venir ] ─► sortie
//
// Toutes les sources sortent sur srcBus : en ajouter une (looper, POLY…)
// ne change rien à la suite de la chaîne.
// Les effets travaillent sur place : chacun lit srcBus et y remet son
// résultat (ReplaceOut), dans l'ordre des synths du groupe grpFx. Un effet
// en bypass est mis en pause : il ne touche plus au bus et ne coûte rien.
// Les SynthDefs sont dans SculptDefs.sc ; ce fichier crée les synths, les
// bus et les buffers, et répond aux commandes de Lua.
Engine_Sculpt : CroneEngine {
	// un fichier est chargé en RAM, 5 min au plus
	classvar <maxSeconds = 300;
	// colonnes de la forme d'onde envoyée à Lua (largeur de l'écran)
	classvar <waveCols = 128;
	// MOSAIC : buffer circulaire de 4 s, comme sur le S4
	classvar <mosSeconds = 4;
	// nombre d'enveloppes de grain précalculées pour CONTOUR (de -1 à +1)
	classvar <contourSteps = 9;

	var srcBus, grpSrc, grpFx, grpOut, player, outSynth;
	var grpMos, grpRing, ringCtl, ringShape, ringSynth, ringArgs, ringWet = 0.5;
	var grpDef, defSynth, defArgs, defWet = 0.5;
	var mosaic, mosBufs, envBufs, mosFunc, mosBypassed = true;
	var buf, pos = 0, posFunc, lua;
	// numéro du dernier chargement demandé : un fichier lent qui arrive
	// après un autre plus récent est ignoré
	var loadId = 0;
	// ce que Lua a demandé (lecture ou arrêt), et un échange de buffer en cours
	var playing = false, swapping = false;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {
		var s = context.server;

		// les messages vers le script Lua (osc.event)
		lua = NetAddr("127.0.0.1", 10111);
		SculptDefs.add;

		srcBus = Bus.audio(s, 2);
		// buffer vide tant qu'aucun fichier n'est chargé
		buf = Buffer.alloc(s, 4, 2);
		// MOSAIC : un buffer mono par côté (GrainBuf ne lit que du mono)
		mosBufs = 2.collect { Buffer.alloc(s, (s.sampleRate * mosSeconds).asInteger, 1) };
		envBufs = Buffer.allocConsecutive(contourSteps, s, 1024, 1);
		s.sync;
		envBufs.do { |b, i|
			b.setn(0, this.contourEnv((i / (contourSteps - 1) * 2) - 1, 1024));
		};
		s.sync;

		grpSrc = Group.new(context.xg, \addToHead);
		grpFx = Group.after(grpSrc);
		grpOut = Group.after(grpFx);
		// un groupe par étage : l'ordre de la chaîne tient même quand un
		// effet est défait et refait
		grpMos = Group.tail(grpFx);
		grpRing = Group.tail(grpFx);
		ringCtl = Bus.control(s, SculptDefs.ringBands * 3);
		grpDef = Group.tail(grpFx);
		defArgs = IdentityDictionary[
			\drive -> 0, \crush -> 0, \crushMode -> 0, \comp -> 0, \tilt -> 0,
			\xover -> 650, \noise -> 0, \noiseType -> 1, \noiseDecay -> 0.2,
			\noiseTone -> 1200,
			// en cours de calage à l'oreille, voués à devenir des constantes
			\law -> 1, \grain -> 0, \grainTone -> 2000
		];
		ringArgs = IdentityDictionary[
			\cutoff -> 16000, \reso -> 0, \decay -> 0, \pitch -> 0,
			\slope -> -1, \tone -> 0, \tilt -> 0
		];
		player = Synth(\sculpt_player, [\out, srcBus, \buf, buf], grpSrc);
		// les effets démarrent en bypass, donc en pause
		mosaic = Synth.newPaused(\sculpt_mosaic, [\bus, srcBus, \bufL, mosBufs[0], \bufR, mosBufs[1],
			\envBase, envBufs[0].bufnum, \envSteps, contourSteps, \bypass, 1], grpMos);
		outSynth = Synth(\sculpt_out, [\in, srcBus, \out, context.out_b.index], grpOut);

		// La tête d'écriture de MOSAIC (0..1) et le niveau écrit, relayés à
		// Lua tels quels : un poll les lisserait et en perdrait en route.
		mosFunc = OSCFunc({ |msg| lua.sendMsg("/sculpt/mos", msg[3], msg[4]) }, '/sculpt/mos');

		posFunc = OSCFunc({ |msg| pos = msg[3] }, '/sculpt/pos');
		this.addPoll(\play_pos, { pos });

		// (pas « load » : engine.load est déjà une fonction de norns)
		this.addCommand(\file, "s", { |msg| this.loadFile(msg[1].asString) });
		// 1 : lecture depuis le début ; 0 : arrêt
		this.addCommand(\play, "i", { |msg|
			playing = msg[1] > 0;
			// pendant un échange de buffer, la lecture repartira à sa fin
			if(swapping.not) {
				if(playing) { player.set(\t_reset, 1, \play, 1) } { player.set(\play, 0) };
			};
		});
		this.addCommand(\level, "f", { |msg| player.set(\level, msg[1]) });

		// MOSAIC : une commande par réglage, du même nom que l'argument du synth
		[\pitch, \rate, \size, \contour, \scan, \spray, \feedback, \wet].do { |key|
			this.addCommand(("mos_" ++ key).asSymbol, "f", { |msg| mosaic.set(key, msg[1]) });
		};
		// 0 : retard (DELAY FREE), 1 : position fixe
		this.addCommand(\mos_scan_mode, "i", { |msg| mosaic.set(\scanMode, msg[1]) });
		this.addCommand(\mos_lock, "i", { |msg| mosaic.set(\lock, msg[1]) });
		this.addCommand(\mos_bypass, "i", { |msg| this.setBypass(msg[1] > 0) });

		// RING : les réglages sont gardés ici, puisque le synth n'existe pas
		// tant que l'effet est éteint
		[\cutoff, \reso, \decay, \pitch, \slope, \tone, \tilt].do { |key|
			this.addCommand(("ring_" ++ key).asSymbol, "f", { |msg|
				ringArgs[key] = msg[1];
				ringShape !? { ringShape.set(key, msg[1]) };
			});
		};
		this.addCommand(\ring_wet, "f", { |msg|
			ringWet = msg[1];
			ringSynth !? { ringSynth.set(\wet, msg[1]) };
		});
		this.addCommand(\ring_bypass, "i", { |msg| this.setRing(msg[1] == 0) });

		// DEFORM : mêmes règles que RING
		[\drive, \crush, \crushMode, \comp, \tilt, \xover,
			\noise, \noiseType, \noiseDecay, \noiseTone,
			\law, \grain, \grainTone].do { |key|
			this.addCommand(("def_" ++ key).asSymbol, "f", { |msg|
				defArgs[key] = msg[1];
				defSynth !? { defSynth.set(key, msg[1]) };
			});
		};
		this.addCommand(\def_wet, "f", { |msg|
			defWet = msg[1];
			defSynth !? { defSynth.set(\wet, msg[1]) };
		});
		this.addCommand(\def_bypass, "i", { |msg| this.setDeform(msg[1] == 0) });
	}

	// Bypass de MOSAIC : le synth fait un fondu vers le signal direct, puis il
	// est mis en pause. Au retour, il reprend avant de rouvrir l'effet.
	// Le buffer est effacé à la mise en pause : sans ça, il garde ce qu'il
	// contenait et le rallumage ressort un bout du son d'avant. On préfère
	// un début silencieux, le temps que la tête d'écriture remplisse.
	setBypass { |on|
		mosBypassed = on;
		if(on) {
			mosaic.set(\bypass, 1);
			{ 0.1.wait; if(mosBypassed) { mosaic.run(false); mosBufs.do(_.zero) } }.fork;
		} {
			mosaic.run(true);
			mosaic.set(\bypass, 0);
		};
	}

	// RING s'allume et s'éteint en se défaisant : un filtre résonnant garde
	// de l'énergie, et un synth seulement mis en pause la relâcherait au
	// rallumage. Éteint, il ne coûte donc rien non plus.
	setRing { |on|
		if(on) {
			if(ringSynth.isNil) {
				ringShape = Synth(\sculpt_ring_shape,
					[\out, ringCtl.index] ++ ringArgs.getPairs, grpRing);
				ringSynth = Synth(\sculpt_ring,
					[\bus, srcBus, \ctl, ringCtl.index, \wet, ringWet, \bypass, 1],
					ringShape, \addAfter);
				ringSynth.set(\bypass, 0);
			};
		} {
			if(ringSynth.notNil) {
				var syn = ringSynth, shp = ringShape;
				ringSynth = nil; ringShape = nil;
				syn.set(\bypass, 1);
				{ 0.12.wait; syn.free; shp.free; }.fork;
			};
		};
	}

	// DEFORM s'allume et s'éteint comme RING, en se faisant et se défaisant.
	setDeform { |on|
		if(on) {
			if(defSynth.isNil) {
				defSynth = Synth(\sculpt_deform,
					[\bus, srcBus, \wet, defWet, \bypass, 1] ++ defArgs.getPairs, grpDef);
				defSynth.set(\bypass, 0);
			};
		} {
			if(defSynth.notNil) {
				var syn = defSynth;
				defSynth = nil;
				syn.set(\bypass, 1);
				{ 0.12.wait; syn.free; }.fork;
			};
		};
	}

	// Enveloppe d'un grain pour CONTOUR = k. Au centre (0) : une cloche
	// douce. Vers -1 : attaque franche puis descente (percussif). Vers +1 :
	// montée puis fin franche (effet « à l'envers »).
	contourEnv { |k, n|
		^Array.fill(n, { |j|
			var x = j / (n - 1);
			var bell = (x * pi).sin.squared;
			var ramp = if(k < 0) {
				if(x < 0.02) { x / 0.02 } { 1 - ((x - 0.02) / 0.98) };
			} {
				if(x > 0.98) { (1 - x) / 0.02 } { x / 0.98 };
			};
			(bell * (1 - k.abs)) + (ramp * k.abs);
		});
	}

	// Forme d'onde approximative : pour chaque colonne, la crête d'un court
	// extrait pris à cet endroit du fichier. Lire tout un fichier de 5 min
	// dans sclang serait trop long.
	wavePeaks { |sf, frames|
		var chunk = 512;
		^waveCols.collect { |i|
			// readData raccourcit le tableau en fin de fichier : un neuf par colonne
			var data = Signal.newClear(chunk * sf.numChannels);
			sf.seek((i * frames / waveCols).asInteger, 0);
			sf.readData(data);
			if(data.size > 0) { data.peak } { 0 };
		};
	}

	// Charge un fichier en RAM, puis le donne au lecteur. Répond à Lua par
	// /sculpt/loaded : durée en secondes (0 = échec), puis la forme d'onde.
	loadFile { |path|
		var s = context.server;
		var sf = SoundFile.openRead(path);
		var id, frames, peaks, channels, seconds;
		loadId = loadId + 1;
		id = loadId;
		if(sf.isNil) {
			("sculpt: cannot read " ++ path).postln;
			lua.sendMsg("/sculpt/loaded", 0);
			^this;
		};
		frames = min(sf.numFrames, (sf.sampleRate * maxSeconds).asInteger);
		seconds = frames / sf.sampleRate;
		peaks = this.wavePeaks(sf, frames);
		// mono : le même canal des deux côtés ; au-delà de 2 canaux : les 2 premiers
		channels = if(sf.numChannels > 1) { [0, 1] } { [0, 0] };
		sf.close;
		Buffer.readChannel(s, path, 0, frames, channels, action: { |b|
			if(id == loadId) {
				var old = buf;
				// Changer de buffer en pleine lecture ferait un clic : on coupe
				// d'abord le son (fondu de 10 ms dans le synth), on échange,
				// puis la lecture repart du début du nouveau sample.
				// (buf change tout de suite côté sclang : si un autre chargement
				// arrive pendant le fondu, chacun libère bien son ancien buffer)
				buf = b;
				swapping = true;
				player.set(\play, 0);
				{
					0.04.wait;
					player.set(\buf, b, \t_reset, 1);
					swapping = false;
					if(playing) { player.set(\play, 1) };
					lua.sendMsg("/sculpt/loaded", seconds, *peaks);
					0.2.wait;
					old.free;
				}.fork;
			} {
				b.free;
			};
		});
	}

	free {
		posFunc.free;
		mosFunc.free;
		[player, mosaic, ringShape, ringSynth, defSynth, outSynth,
			grpSrc, grpMos, grpRing, grpDef, grpFx, grpOut].do { |x| x !? { x.free } };
		ringCtl.free;
		[srcBus, buf].do(_.free);
		mosBufs.do(_.free);
		envBufs.do(_.free);
	}
}
