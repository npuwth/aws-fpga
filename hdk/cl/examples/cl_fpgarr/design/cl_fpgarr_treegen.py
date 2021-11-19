import math
import argparse
import sys
"""
This is the merge-tree configuration generator for the packing module.
Example:
python3 cl_fpgarr_treegen.py --name record --CW 32,36,32,32,36,32,32,36,32,531,18,91,593,91
"""
RR_CHANNEL_WIDTH_BITS = 32
RR_CHANNEL_NAME_BITS = 32*8
parser = argparse.ArgumentParser(description=
    "Generate packing merge tree configuration, can specify multiple pair "
    "of name and channel widths")
parser.add_argument('-svh', '--svh-output', metavar='file_name', type=str,
    default="cl_fpgarr_packing_cfg.svh",
    help="output verilog parameter to this file (default: %(default)s)")
parser.add_argument('-hpp', '--hpp-output', metavar='file_name', type=str,
    default="cl_fpgarr_buscfg.hpp",
    help="output trace decoder cpp header to this file (default: %(default)s")

# {{{ Divide Rules
class DivideRule(object):
  # input is a list of channel widths
  # returns is a tuple, two list of channel widths, the wider one goes first
  @classmethod
  def divide_one_layer(cls, CW, idxs):
    assert(0 and "Should instantiate this function");

class DivideBySum(DivideRule):
  NAME="dividebysum"
class DivideByEvenHeadTail(DivideRule):
  NAME="dp"
# }}} Divide Rules

# Make use of divide rules
class MergePlan(object):
  NAME="PLAN TEMPLATE NAME"
  SEP = '------'
  # CW: all channel widths
  def __init__(self, name, CW, args):
    # list of layer plan
    #   each layer plan is a list of node plan and has a height
    #   layer height > 0 has merge (M) or Queue(Q) plan
    #   layer height == 0 only has Q plan to reorder input
    # each node plan is a tuple (id of the previous layer to merge), if two ids
    # equals, means a queue
    self.name = name
    self.plan = []
    self.CW = CW
    self.dbg_msg = ""
    self.args = args
    self.run_plan()

  def run_plan(self):
    N = len(self.CW)
    init_idxs = range(N)
    h, nid, msg = self.plan_merge(init_idxs)
    print(msg)
    if args.verbose:
      print("dbg msg:\n%s" % self.dbg_msg)

  # idxs: the index of leafs to consider
  # returns: (height, node id, info_msg)
  # hight is from the leaf, start from 0
  def plan_merge(self, idxs):
    assert(0 and "Please instantiate me")

  # return node id of the added plan on that layer
  # plan is a tuple (lid, rid)
  # lid != rid is a merge node
  # lid == rid is a queue node
  def addNodePlan(self, height, plan):
    if len(self.plan) < height + 1:
      self.plan.append([])
    self.plan[height].append(plan)
    return len(self.plan[height]) - 1
  def get_layer_plan(self, h, max_N):
    layer_plan = self.plan[h]
    plans_str = []
    for i in range(max_N):
      if i < len(layer_plan):
        np = layer_plan[i] # node plan
        plans_str.append("\'{%d, %d}" % (np[0], np[1]))
      else:
        plans_str.append("\'{0, 0}")
    return '\'{' + ', '.join(plans_str) + '}'

  # f: opened file object
  def writeVerilogParameters(self, f, indent=2, SEP=' '):
    # output four parameter
    # MERGE_TREE_HEIGHT
    # MERGE_TREE_MAX_NODES
    # int NODES_PER_LAYER [MERGE_TREE_HEIGHT-1:0]
    # int MERGE_PLAN [MERGE_TREE_HEIGHT-1:0][MERGE_TREE_MAX_NODES-1:0][1:0]
    h = len(self.plan)
    nodes_per_layer = [len(x) for x in self.plan]
    max_N = max(nodes_per_layer)
    prefix = SEP * indent
    f.write("package {}_pkg;\n".format(self.name))
    f.write(prefix +
        "// height of the merge tree, layer 0 is for reorder input\n")
    f.write(prefix +
        "parameter MERGE_TREE_HEIGHT=%d;\n" % h)
    f.write(prefix +
        "// max number of nodes across all layers/height\n")
    f.write(prefix +
        "parameter MERGE_TREE_MAX_NODES=%d;\n" % max_N)
    f.write(prefix +
        "// number of nodes inside each layer, "
        "used to terminate generate for-loop\n")
    f.write(prefix +
        "parameter int NODES_PER_LAYER [0:MERGE_TREE_HEIGHT-1] = "
        "\'{ %s };\n" % ', '.join([str(x) for x in nodes_per_layer]))
    f.write(prefix +
        "// actual merge plan [layer][node][plan], each plan is "
        "a two-integer tuple, meaning the idx of nodes to merge or queue "
        "in the previous layer. Equal idx means queue, else means merge.\n"
        "// Height 0 is to shuffle the init channel width.\n")
    # generate the actual plan
    merge_plan = ', \n'.join([self.get_layer_plan(i, max_N)
      for i in range(h)])
    f.write(prefix +
        "parameter int MERGE_PLAN [0:MERGE_TREE_HEIGHT-1] "
        "[0:MERGE_TREE_MAX_NODES-1] [0:1] = \'{\n%s\n};\n" % merge_plan)
    # a shortcut to the shuffling plan (MERGE_PLAN[0])
    f.write(prefix +
        "// a shortcut to the shuffling plan (MERGE_PLAN[0])\n")
    f.write(prefix +
        "parameter int SHUFFLE_PLAN [0:MERGE_TREE_MAX_NODES-1] [0:1] = "
        "MERGE_PLAN[0];\n")
    f.write("endpackage\n")

  # f is an opened file object
  # plans is a list of MergePlan()
  @classmethod
  def exportAllPlan(cls, f, plans):
    f.write("`ifndef CL_FPGARR_PACKING_CFG_H\n")
    f.write("`define CL_FPGARR_PACKING_CFG_H\n")
    for p in plans:
      p.writeVerilogParameters(f)
    f.write("`endif // CL_FPGARR_PACKING_CFG_H\n")

class DivideBySumPlan(MergePlan):
  NAME="dividebysum"
  def divide_one_layer(self, CW, idxs):
    s = sorted(idxs, key=lambda x: CW[x], reverse=True)
    suma = sum(CW)
    suml = 0
    l = []
    sumr = 0
    r = []
    for wid in s:
      if suml > sumr and (len(l) > len(r) or CW[wid]/suma > 0.01):
        r.append(wid)
        sumr += CW[wid]
      else:
        l.append(wid)
        suml += CW[wid]
    # Putting more bits on the left and fewer bits on the right saves resource
    if suml > sumr:
      return (l, r)
    else:
      return (r, l)
  def plan_merge(self, idxs):
    CW = self.CW
    if len(idxs) == 1:
      cwid = idxs[0]
      nid = self.addNodePlan(0, (cwid, cwid))
      msg = "ID(%d) Q(%d) W%d\n" % (nid, cwid, CW[cwid])
      return (0, nid, msg)
    else:
      l_idxs, r_idxs = self.divide_one_layer(CW, idxs)
      self.dbg_msg += "dbg, divide %s to\n%s\n%s\n" % (
        str([CW[i] for i in idxs]),
        str([CW[i] for i in l_idxs]),
        str([CW[i] for i in r_idxs])
      )
      lh, lid, l_msg = self.plan_merge(l_idxs)
      rh, rid, r_msg = self.plan_merge(r_idxs)
      h = max(lh, rh)
      # insert queue node in the tree
      lhq = lh
      while lhq < h:
        lid_next = self.addNodePlan(lhq+1, (lid, lid))
        l_msg += self.SEP*(lhq+1) + "> ID(%d) Q(%d) W%d\n" % (
          lid_next, lid, sum([CW[x] for x in l_idxs])
        )
        lid = lid_next
        lhq = lhq + 1
      rhq = rh
      while rhq < h:
        rid_next = self.addNodePlan(rhq+1, (rid, rid))
        r_msg += self.SEP*(rhq+1) + "> ID(%d) Q(%d) W%d\n" % (
          rid_next, rid, sum([CW[x] for x in r_idxs])
        )
        rid = rid_next
        rhq = rhq + 1
      # merge
      nid = self.addNodePlan(h+1, (lid, rid))
      msg = l_msg + r_msg
      msg += self.SEP*(h+1) + "> ID(%d) M(%d, %d) W%d\n" % (
        nid, lid, rid, sum([CW[x] for x in idxs])
      )
      return (h+1, nid, msg)

class DivideByDPPlan(DivideBySumPlan):
  NAME="divdp"
  def divide_one_layer(self, CW, idxs):
    # CW from min to max
    s = sorted(idxs, key=lambda x: CW[x])
    N = len(s)
    suma = sum([CW[i] for i in idxs])
    if N == 2:
      return ([s[1]], [s[0]])
    pairs = [] # (sum(first.width, second.width), first.id, second.id)
    if N % 2:
      odd_id = s.pop()
      pairs.append((CW[odd_id], odd_id, odd_id))
      N -= 1
    # for the rest of the CW, pair a max with a min
    # this is to reduce the variance of the width of the merged chanels in the
    # next layer
    for i in range(N//2):
      first = s[N - 1 - i]
      second = s[i]
      pairs.append((CW[first] + CW[second], first, second))
    # 01-bag packing, dp
    half_goal = suma // 2
    dp = [0] * (half_goal + 1)
    dp_solution = [set()] * (half_goal + 1)
    for i in range(len(pairs)):
      w = pairs[i][0]
      for j in range(half_goal, w - 1, -1):
        if dp[j] < dp[j-w] + w:
          dp[j] = dp[j-w] + w
          dp_solution[j] = dp_solution[j-w].copy()
          dp_solution[j].add(i)
    # put (< half_goal) solution to the right
    r_idxs = set()
    for i in dp_solution[half_goal]:
      r_idxs.add(pairs[i][1])
      r_idxs.add(pairs[i][2])
    l_idxs = set(idxs) - r_idxs
    return (list(l_idxs), list(r_idxs))

class DivideGreedyPlan(MergePlan):
  NAME="greedy"
  def plan_merge(self, idxs):
    # recursive idxs
    self.all_plan = []
    ridxs = idxs
    rCW = self.CW
    while len(ridxs) > 1:
      pairs = self.plan_one_layer(rCW, ridxs)
      self.all_plan.append(pairs)
      next_CW = []
      for w, _, _ in pairs:
        next_CW.append(w)
      rCW = next_CW
      ridxs = range(len(pairs))
    h = len(self.all_plan)
    nid, msg = self.registerPlan(h-1, 0)
    return (h, nid, msg)
  # recursive register node idx at height h
  # return (registered id, info_msg)
  def registerPlan(self, h, idx):
    if (h == -1):
      # termination case: leaf node
      nid = self.addNodePlan(0, (idx, idx))
      msg = "ID(%d) Q(%d) W%d\n" % (nid, idx, self.CW[idx])
      return (nid, msg)
    assert(h < len(self.all_plan))
    assert(idx < len(self.all_plan[h]))
    w, lid, rid = self.all_plan[h][idx]
    if lid != rid: # merge node
      lnid, l_msg = self.registerPlan(h-1, lid)
      rnid, r_msg = self.registerPlan(h-1, rid)
      nid = self.addNodePlan(h+1, (lnid, rnid))
      msg = l_msg + r_msg
      msg += self.SEP*(h+1) + "> ID(%d) M(%d, %d) W%d\n" % (nid, lnid, rnid, w)
      return (nid, msg)
    else: # queue node
      lnid, msg = self.registerPlan(h-1, lid)
      nid = self.addNodePlan(h+1, (lnid, lnid))
      msg += self.SEP*(h+1) + "> ID(%d) Q(%d) W%d\n" % (nid, lnid, w)
      return (nid, msg)
  def plan_one_layer(self, CW, idxs):
    # CW from min to max
    s = sorted(idxs, key=lambda x: CW[x])
    self.dbg_msg += "sorted %s\n" % (str([CW[i] for i in s]))
    N = len(s)
    pairs = [] # (sum(first.width, second.width), first.id, second.id)
    if N % 2:
      odd_id = s.pop()
      pairs.append((CW[odd_id], odd_id, odd_id))
      N -= 1
    # for the rest of the CW, pair a max with a min
    # this is to reduce the variance of the width of the merged chanels in the
    # next layer
    for i in range(N//2):
      first = s[N - 1 - i]
      second = s[i]
      w = CW[first] + CW[second]
      pairs.append((w, first, second))
    self.dbg_msg += "pairs: %s\n" % (str(
      [(w,CW[lid],CW[rid]) for w, lid, rid in pairs]
    ))
    return pairs

# Divide rule configurations
ALL_RULES = [DivideBySumPlan, DivideByDPPlan, DivideGreedyPlan]
ALL_RULES_MAP = dict([(cls.NAME, cls) for cls in ALL_RULES])
DEFAULT_RULE = DivideBySumPlan
parser.add_argument('-p', '--plan', metavar='divide_plan', type=str,
    action="append", choices=ALL_RULES_MAP.keys(), default=[],
    help="How should I divide? (default: %(default)s, choices: %(choices)s)")
parser.add_argument('-v', '--verbose', action="store_true", default=False,
    help="print debug messages")
args = parser.parse_args()

RAW_CFGS = [
  "record,         14,         25,         11,0000005b000002510000005b0000001200000213000000200000002400000020000000200000002400000020000000200000002400000020,00000000000000000000000000000000000000000000000000706369735f41520000000000000000000000000000000000000000000000000000706369735f5700000000000000000000000000000000000000000000000000706369735f415700000000000000000000000000000000000000000000000000007063696d5f4200000000000000000000000000000000000000000000000000007063696d5f5200000000000000000000000000000000000000000000000000626172315f41520000000000000000000000000000000000000000000000000000626172315f5700000000000000000000000000000000000000000000000000626172315f415700000000000000000000000000000000000000000000000000006f636c5f41520000000000000000000000000000000000000000000000000000006f636c5f5700000000000000000000000000000000000000000000000000006f636c5f415700000000000000000000000000000000000000000000000000007364615f41520000000000000000000000000000000000000000000000000000007364615f5700000000000000000000000000000000000000000000000000007364615f4157,0000000000000000000000000000000000000000000000000000706369735f520000000000000000000000000000000000000000000000000000706369735f4200000000000000000000000000000000000000000000000000706369735f41520000000000000000000000000000000000000000000000000000706369735f5700000000000000000000000000000000000000000000000000706369735f415700000000000000000000000000000000000000000000000000007063696d5f5200000000000000000000000000000000000000000000000000007063696d5f42000000000000000000000000000000000000000000000000007063696d5f415200000000000000000000000000000000000000000000000000007063696d5f57000000000000000000000000000000000000000000000000007063696d5f41570000000000000000000000000000000000000000000000000000626172315f520000000000000000000000000000000000000000000000000000626172315f4200000000000000000000000000000000000000000000000000626172315f41520000000000000000000000000000000000000000000000000000626172315f5700000000000000000000000000000000000000000000000000626172315f41570000000000000000000000000000000000000000000000000000006f636c5f520000000000000000000000000000000000000000000000000000006f636c5f4200000000000000000000000000000000000000000000000000006f636c5f41520000000000000000000000000000000000000000000000000000006f636c5f5700000000000000000000000000000000000000000000000000006f636c5f41570000000000000000000000000000000000000000000000000000007364615f520000000000000000000000000000000000000000000000000000007364615f4200000000000000000000000000000000000000000000000000007364615f41520000000000000000000000000000000000000000000000000000007364615f5700000000000000000000000000000000000000000000000000007364615f4157",
  "validate,         11,         25,         11,00000012000002130000005b000002510000005b000000020000002200000002000000220000000200000022,0000000000000000000000000000000000000000000000000000706369735f420000000000000000000000000000000000000000000000000000706369735f52000000000000000000000000000000000000000000000000007063696d5f415200000000000000000000000000000000000000000000000000007063696d5f57000000000000000000000000000000000000000000000000007063696d5f41570000000000000000000000000000000000000000000000000000626172315f420000000000000000000000000000000000000000000000000000626172315f520000000000000000000000000000000000000000000000000000006f636c5f420000000000000000000000000000000000000000000000000000006f636c5f520000000000000000000000000000000000000000000000000000007364615f420000000000000000000000000000000000000000000000000000007364615f52,0000000000000000000000000000000000000000000000000000706369735f520000000000000000000000000000000000000000000000000000706369735f4200000000000000000000000000000000000000000000000000706369735f41520000000000000000000000000000000000000000000000000000706369735f5700000000000000000000000000000000000000000000000000706369735f415700000000000000000000000000000000000000000000000000007063696d5f5200000000000000000000000000000000000000000000000000007063696d5f42000000000000000000000000000000000000000000000000007063696d5f415200000000000000000000000000000000000000000000000000007063696d5f57000000000000000000000000000000000000000000000000007063696d5f41570000000000000000000000000000000000000000000000000000626172315f520000000000000000000000000000000000000000000000000000626172315f4200000000000000000000000000000000000000000000000000626172315f41520000000000000000000000000000000000000000000000000000626172315f5700000000000000000000000000000000000000000000000000626172315f41570000000000000000000000000000000000000000000000000000006f636c5f520000000000000000000000000000000000000000000000000000006f636c5f4200000000000000000000000000000000000000000000000000006f636c5f41520000000000000000000000000000000000000000000000000000006f636c5f5700000000000000000000000000000000000000000000000000006f636c5f41570000000000000000000000000000000000000000000000000000007364615f520000000000000000000000000000000000000000000000000000007364615f4200000000000000000000000000000000000000000000000000007364615f41520000000000000000000000000000000000000000000000000000007364615f5700000000000000000000000000000000000000000000000000007364615f4157"
]
class BusConfig(object):
  def __init__(self, cfg_string):
    s = cfg_string.split(',')
    self.NAME = s[0]
    self.LOGB_CNT = int(s[1])
    self.LOGE_CNT = int(s[2])
    self.OFFSET_WIDTH = int(s[3])
    # parse CW
    CW_str = s[4]
    self.CW = self._parse_CW(CW_str)
    print("name: " + self.NAME)
    print("CW: %s" % (str(self.CW)))
    # parse LOGB_NAMES
    logb_names_str = s[5]
    self.LOGB_NAMES = self._parse_NAMES(self.LOGB_CNT, logb_names_str)
    print("LOGB_NAME: %s" % (str(self.LOGB_NAMES)))
    # parse LOGE_NAMES
    loge_names_str = s[6]
    self.LOGE_NAMES = self._parse_NAMES(self.LOGE_CNT, loge_names_str)
    print("LOGE_NAME: %s" % (str(self.LOGE_NAMES)))
  def _parse_CW(self, CW_str):
    CW = []
    for i in range(1, self.LOGB_CNT + 1):
      l = len(CW_str) - i*RR_CHANNEL_WIDTH_BITS//4
      r = l + RR_CHANNEL_WIDTH_BITS//4
      CW.append(int("0x"+CW_str[l:r], base=16))
    return CW
  def _parse_NAMES(self, cnt, name_str):
    NAMES = []
    for i in range(1, cnt + 1):
      l = len(name_str) - i*RR_CHANNEL_NAME_BITS//4
      r = l + RR_CHANNEL_NAME_BITS//4
      s = name_str[l:r]
      name = ""
      for j in range(len(s)//2):
        byte = int("0x"+s[2*j:2*j+2], base=16)
        if byte != 0:
          name += chr(byte)
      NAMES.append(name)
    return NAMES

  # f: opened file object
  @classmethod
  def writeCPPHeader(cls, f):
    f.write(
        "#ifndef CL_FPGARR_BUSCFG_H\n"
        "#define CL_FPGARR_BUSCFG_H\n"
        "#include <array>\n"
    )
  @classmethod
  def writeCPPFooter(cls, f):
    f.write("#endif // CL_FPGARR_BUSCFG_H\n")
  @classmethod
  def writeCPPStructDefine(cls, f):
    f.write(
        "typedef struct {\n"
        "  const char *NAME;\n"
        "  const int LOGB_CNT;\n"
        "  const int LOGE_CNT;\n"
        "  const int OFFSET_WIDTH;\n"
        "  const std::vector<int> CW;\n"
        "  const std::vector<std::string> LOGB_NAMES;\n"
        "  const std::vector<std::string> LOGE_NAMES;\n"
        "} busconfig_t;\n"
    )

  # p is a MergePlan
  def exportShuffleBus(self, f, p):
    shuffle_plan = p.plan[0]
    # Note that LOGE is not shuffled
    shuffled_CW = []
    shuffled_LOGB_NAMES = []
    for lid, rid in shuffle_plan:
      assert(lid == rid)
      shuffled_CW.append(self.CW[lid])
      shuffled_LOGB_NAMES.append(self.LOGB_NAMES[lid])
    busname = self.NAME + "_bus"
    f.write(
        "struct {}_t {{\n".format(busname) +
        "  static constexpr const char NAME[]=\"{}\";\n".format(busname) +
        "  static constexpr const int LOGB_CNT={};\n".format(self.LOGB_CNT) +
        "  static constexpr const int LOGE_CNT={};\n".format(self.LOGE_CNT) +
        "  static constexpr const int OFFSET_WIDTH={};\n".format(self.OFFSET_WIDTH) +
        "  static constexpr const std::array<int, LOGB_CNT> CW={{{}}};\n".format(
          ', '.join([str(w) for w in shuffled_CW])) +
        "  static constexpr const std::array<const char*, LOGB_CNT> LOGB_NAMES={{{}}};\n".format(
          ', '.join(["\"{}\"".format(s) for s in shuffled_LOGB_NAMES])) +
        "  static constexpr const std::array<const char*, LOGE_CNT> LOGE_NAMES={{{}}};\n".format(
          ', '.join(["\"{}\"".format(s) for s in self.LOGE_NAMES])) +
        "};\n"
    )

cfgs = [BusConfig(rawcfg) for rawcfg in RAW_CFGS]
plans = []
if len(args.plan) == 0:
  divide_plans = [DEFAULT_RULE] * len(names)
if len(args.plan) == 1:
  divide_plans = [ALL_RULES_MAP[args.plan[0]]] * len(names)
else:
  divide_plans = [ALL_RULES_MAP[p] for p in args.plan]
for buscfg, plan in zip(cfgs, divide_plans):
  print("#"*80)
  print("name: %s, using divide_plan %s, CW_int: %s" % (
    buscfg.NAME, plan.NAME, str(buscfg.CW)))
  plan = plan(buscfg.NAME, buscfg.CW, args)
  plans.append(plan)
with open(args.svh_output, 'wt') as f:
  f.write("// automatically generated by %s\n" % ' '.join(sys.argv))
  MergePlan.exportAllPlan(f, plans)
with open(args.hpp_output, 'wt') as f:
  f.write("// automatically generated by %s\n" % ' '.join(sys.argv))
  BusConfig.writeCPPHeader(f)
  for buscfg, p in zip(cfgs, plans):
    buscfg.exportShuffleBus(f, p)
  BusConfig.writeCPPFooter(f)
