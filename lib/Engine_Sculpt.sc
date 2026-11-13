// Engine_Sculpt : le moteur de sculpt.
//
//   source (lecteur de sample) ─► srcBus ─► [ chaîne d'effets, à venir ] ─► sortie
//
// Toutes les sources sortent sur srcBus : en ajouter une (looper, POLY…)
// ne change rien à la suite de la chaîne.
// Les SynthDefs sont dans SculptDefs.sc ; ce fichier crée les synths, les
// bus et les buffers, et répond aux commandes de Lua.
Engine_Sculpt : CroneEngine {
	// un fichier est chargé en RAM, 5 min au plus
	classvar <maxSeconds = 300;
	// colonnes de la forme d'onde envoyée à Lua (largeur de l'écran)
	classvar <waveCols = 128;

	var srcBus, grpSrc, grpOut, player, outSynth;
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
		s.sync;

		grpSrc = Group.new(context.xg, \addToHead);
		grpOut = Group.after(grpSrc);
		player = Synth(\sculpt_player, [\out, srcBus, \buf, buf], grpSrc);
		outSynth = Synth(\sculpt_out, [\in, srcBus, \out, context.out_b.index], grpOut);

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
		[player, outSynth, grpSrc, grpOut].do(_.free);
		[srcBus, buf].do(_.free);
	}
}
