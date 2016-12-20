part of otdartlib.atext_changeset;

/*
 * Construct a new changeset object. Usually changesets are not created directly, but by a Builder.
 *
 * @param {ComponentList} ops - a list of operations
 * @param {Number} oldLen - old len of the document that changeset is applied to
 * @param? {string} optAuthorId - optional author of the changeset
 * @param? {Number} optNewLen - optional length of the document after applied changeset. If not supplied,
 *                              will be calculated from the changeset data.
 */
class Changeset extends ComponentList {
  int _oldLen;
  int _newLen;
  String _author;
  
  static final _headerRegex = new RegExp(r'X:([0-9a-z]+)([><])([0-9a-z]+)|/');
  
  
  Changeset(Iterable<OpComponent> ops, this._oldLen, { String author, int newLen }) : super.from(ops) {
    _author = author;
    _newLen = newLen ?? (_oldLen + fold(0,  (prev, op) => prev + op.deltaLen));
  }

  /**
   * Unpacks operation from storage object format and returns Changeset object.
   */
  Changeset.unpack(Map cs) {
    String op = cs['op'];
    
    var header = _headerRegex.matchAsPrefix(op);
    if(header == null) {
      throw new Exception('wrong changeset');
    }
  
    _oldLen = _util.parseInt36(header[1]);
    var sign = (header[2] == '>') ? 1 : -1;
    var delta = _util.parseInt36(header[3]);
    _newLen = _oldLen + sign * delta;
  
    var splitPos = op.indexOf(r'$');
    var charBank = splitPos < 0 ? '' : op.substring(splitPos + 1);
    var astr = new AString(atts: op.substring(header[0].length, splitPos < 0 ? null : splitPos), text: charBank);
    
    super._unpack(astr, cs['p']);
    _author = cs['u'];

    int calculatedDelta = deltaLen.abs();
    if(delta != calculatedDelta) {
      throw new Exception('changeset delta ($delta) does not match operations delta ($calculatedDelta)');
    }
  }
  
  /**
   * Create and return changeset builder
   */
  static Builder create(ADocument doc, { String author }) => new Builder(doc, author: author);

  
  // explanation for side = [left | right]
  // let's say we have thisOp coming to server after otherOp,
  // both creating a "tie" situation.
  // server has [otherOp, thisOp]
  // for server otherOp is already written, so it transforms thisOp
  // by otherOp, taking otherOp as first-win and thisOp as second.
  // In [otherOp, thisOp] list otherOp is on the "left"
  // 
  // Server sends its otherOp back to the client, but client already
  // applied thisOp operation, so his queue looks like
  // [thisOp, otherOp]
  // Client should transorm otherOp, and to get same results as server,
  // this time it should take otherOp as first-win. In the list
  // otherOp is to the "right"
  /**
   * Transform this changeset against other changeset.
   */
  Changeset transform(Changeset otherCS, String side) {
    if(_oldLen != otherCS._oldLen) {
      throw new Exception('changesets from different document versions cannot be transformed');
    }
    if(side != 'left' && side != 'right') {
      throw new Exception('side should be \'left\' or \'right\'');
    }
    sort();
    otherCS.sort();

    var mut = new ChangesetTransformer(this, side, otherCS._newLen);

    otherCS.forEach((OpComponent op) => mut.apply(op.slicer));

    return mut.finish();
  }

  /**
   * Compose this changeset with other changeset, producing cumulative result of both changes.
   */
  Changeset compose(Changeset otherCS) {
    if (_newLen != otherCS._oldLen) {
      throw new Exception('changesets from different document versions are not composable');
    }
    sort();
    otherCS.sort();

    var mut = new ChangesetComposer(this);
    otherCS.forEach((OpComponent op) {
      var slicer = op.slicer;

      mut.apply(slicer);

      if (mut.eof && slicer.isNotEmpty) {
        mut.insert(slicer);
      }
    });


    var newCs = mut.finish();
    if(newCs._newLen != otherCS._newLen) {
      throw new Exception('new changeset length (${newCs._newLen}) does not match expected length (${otherCS._newLen})');
    }
    return newCs;
  }

    /*
   * Invert current changeset. That is, inverted changeset if applied to the modified document will produce result
   * that is equal to document before the modification: apply(apply(doc, cs), invert(cs)) == doc
   */
  Changeset invert() {
    return new Changeset(super.inverted, _newLen, author: _author, newLen: _oldLen);
  }

  void applyTo(ADocument doc) {
    sort();

    var mut = new DocumentComposer(doc);
    forEach((OpComponent op) {
      var slicer = op.slicer;
      mut.apply(slicer);

      if (mut.eof && slicer.isNotEmpty) {
        mut.insert(slicer);
      }
    });

    mut.finish();

    if(_newLen != doc.getLength()) {
      throw new Exception('final document length does not match, expected $_newLen, got ${doc.getLength()}');
    }
  }

  /**
   * Pack changeset into compact format that can be stored or transferred by network. 
   */
  Map pack([List pool]) {
    pool ??= [];
    var packed = super.toAString(pool);
    var op = 'X:' + _util.toString36(_oldLen)
      + (packed.dLen >= 0 ? '>' : '<') + _util.toString36(packed.dLen.abs())
      + packed.atts;

    if((_newLen - _oldLen) != packed.dLen) {
      throw new Exception('something wrong with the changeset, internal state broken');
    }
  
    if(packed.text.isNotEmpty) {
      op += r'$' + packed.text;
    }
  
    var cs = { 'op': op, 'p': pool };
    if(_author != null) {
      cs['u'] = _author;
    }
    return cs;
  }
}