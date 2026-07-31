using System;
using System.Collections.Generic;
using msclr;
using std;

// Token: 0x0200000A RID: 10
public class BannedProccessesManaged
{
	// Token: 0x0600013E RID: 318 RVA: 0x00001470 File Offset: 0x00000870
	public static BannedProccessesManaged GetInstance()
	{
		return BannedProccessesManaged.instance;
	}

	// Token: 0x0600013F RID: 319 RVA: 0x0000183C File Offset: 0x00000C3C
	public List<string> GetNormalizedManagedProccesses()
	{
		@lock @lock = null;
		@lock lock2 = new @lock(lockRef._lockRef);
		List<string> list2;
		try
		{
			@lock = lock2;
			List<string> list = this.normalizedProcessManagedStrings;
			if (list != null)
			{
				goto IL_0035;
			}
			list2 = new List<string>(0);
		}
		catch
		{
			((IDisposable)@lock).Dispose();
			throw;
		}
		((IDisposable)@lock).Dispose();
		return list2;
		IL_0035:
		List<string> list3;
		try
		{
			List<string> list;
			list3 = list;
		}
		catch
		{
			((IDisposable)@lock).Dispose();
			throw;
		}
		((IDisposable)@lock).Dispose();
		return list3;
	}

	// Token: 0x06000140 RID: 320 RVA: 0x000018C8 File Offset: 0x00000CC8
	public List<string> GetNormalizedManagedModules()
	{
		@lock @lock = null;
		@lock lock2 = new @lock(lockRef._lockRef);
		List<string> list2;
		try
		{
			@lock = lock2;
			List<string> list = this.normalizedModulesManagedStrings;
			if (list != null)
			{
				goto IL_0035;
			}
			list2 = new List<string>(0);
		}
		catch
		{
			((IDisposable)@lock).Dispose();
			throw;
		}
		((IDisposable)@lock).Dispose();
		return list2;
		IL_0035:
		List<string> list3;
		try
		{
			List<string> list;
			list3 = list;
		}
		catch
		{
			((IDisposable)@lock).Dispose();
			throw;
		}
		((IDisposable)@lock).Dispose();
		return list3;
	}

	// Token: 0x06000141 RID: 321 RVA: 0x00001954 File Offset: 0x00000D54
	public List<string> GetNormalizedManagedTitles()
	{
		@lock @lock = null;
		@lock lock2 = new @lock(lockRef._lockRef);
		List<string> list2;
		try
		{
			@lock = lock2;
			List<string> list = this.normalizedTitleManagedStrings;
			if (list != null)
			{
				goto IL_0035;
			}
			list2 = new List<string>(0);
		}
		catch
		{
			((IDisposable)@lock).Dispose();
			throw;
		}
		((IDisposable)@lock).Dispose();
		return list2;
		IL_0035:
		List<string> list3;
		try
		{
			List<string> list;
			list3 = list;
		}
		catch
		{
			((IDisposable)@lock).Dispose();
			throw;
		}
		((IDisposable)@lock).Dispose();
		return list3;
	}

	// Token: 0x06000142 RID: 322 RVA: 0x00001D00 File Offset: 0x00001100
	public unsafe void SetNormalizedManagedModules(vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* modules)
	{
		this.normalizedModulesManagedStrings = new List<string>(0);
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr = *modules;
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr2 = *(modules + 4);
		if (ptr != ptr2)
		{
			do
			{
				List<string> list = this.normalizedModulesManagedStrings;
				string text = ".dll";
				sbyte* ptr3 = (sbyte*)ptr;
				if (((16 <= *(int*)(ptr + 20 / sizeof(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>))) ? 1 : 0) != 0)
				{
					ptr3 = *(int*)ptr;
				}
				string text2 = new string((sbyte*)ptr3).ToLower() + text;
				list.Add(text2);
				ptr += 24 / sizeof(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>);
			}
			while (ptr != ptr2);
		}
		GC.KeepAlive(this);
	}

	// Token: 0x06000143 RID: 323 RVA: 0x00001D70 File Offset: 0x00001170
	public unsafe void SetNormalizedManagedTitles(vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* titles)
	{
		this.normalizedTitleManagedStrings = new List<string>(0);
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr = *titles;
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr2 = *(titles + 4);
		if (ptr != ptr2)
		{
			do
			{
				List<string> list = this.normalizedTitleManagedStrings;
				sbyte* ptr3 = (sbyte*)ptr;
				if (((16 <= *(int*)(ptr + 20 / sizeof(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>))) ? 1 : 0) != 0)
				{
					ptr3 = *(int*)ptr;
				}
				string text = new string((sbyte*)ptr3).ToLower();
				list.Add(text);
				ptr += 24 / sizeof(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>);
			}
			while (ptr != ptr2);
		}
		GC.KeepAlive(this);
	}

	// Token: 0x06000144 RID: 324 RVA: 0x00001DD4 File Offset: 0x000011D4
	public unsafe void SetNormalizedManagedProccesses(vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* proccesses)
	{
		this.normalizedProcessManagedStrings = new List<string>(0);
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr = *proccesses;
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr2 = *(proccesses + 4);
		if (ptr != ptr2)
		{
			do
			{
				List<string> list = this.normalizedProcessManagedStrings;
				sbyte* ptr3 = (sbyte*)ptr;
				if (((16 <= *(int*)(ptr + 20 / sizeof(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>))) ? 1 : 0) != 0)
				{
					ptr3 = *(int*)ptr;
				}
				string text = new string((sbyte*)ptr3).ToLower();
				list.Add(text);
				ptr += 24 / sizeof(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>);
			}
			while (ptr != ptr2);
		}
		GC.KeepAlive(this);
	}

	// Token: 0x0400008B RID: 139
	private static BannedProccessesManaged instance = new BannedProccessesManaged();

	// Token: 0x0400008C RID: 140
	private List<string> normalizedProcessManagedStrings;

	// Token: 0x0400008D RID: 141
	private List<string> normalizedModulesManagedStrings;

	// Token: 0x0400008E RID: 142
	private List<string> normalizedTitleManagedStrings;
}
