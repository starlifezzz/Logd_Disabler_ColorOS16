/* 模拟 CSS 解析器：未闭合的 ( / function 内，} 不会关闭外层块 —— 这正是"吞尾"的机理 */
module.exports=function check(src, tag){
  const s=src.replace(/\/\*[\s\S]*?\*\//g,m=>" ".repeat(m.length));
  const stack=[]; const errs=[]; let line=1;
  for(let i=0;i<s.length;i++){
    const c=s[i];
    if(c==="\n"){line++;continue;}
    if(c==="(") stack.push({t:"(",line});
    else if(c==="{") stack.push({t:"{",line});
    else if(c===")"){
      if(stack.length&&stack[stack.length-1].t==="(") stack.pop();
      else errs.push("L"+line+" 多余 )");
    }
    else if(c==="}"){
      if(!stack.length){errs.push("L"+line+" 多余 }");}
      else if(stack[stack.length-1].t==="{") stack.pop();
      else errs.push("L"+line+" 的 } 被未闭合的 ( 吞掉 → 该块永不会结束，后续规则整体失效");
    }
  }
  const unclosed=stack.filter(x=>x.t==="(").map(x=>"L"+x.line+" 处的 ( 未闭合");
  const openBlock=stack.filter(x=>x.t==="{").map(x=>"L"+x.line+" 处的 { 未闭合");
  return {ok:!errs.length&&!unclosed.length&&!openBlock.length,
          errs:errs.slice(0,4).concat(unclosed.slice(0,2),openBlock.slice(0,2))};
};
